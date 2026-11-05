#!/usr/bin/env python3
"""Compare actual rendered ASL calls with actual HCL role grants, offline.

This is a source contract check, not IAM Simulation or a claim about SCPs,
boundaries, service propagation, or undocumented condition-key availability.
"""
import importlib.util
import json
from pathlib import Path

DEMO=Path(__file__).resolve().parents[1]

def require(value,message):
    if not value:raise ValueError(message)

def listify(value):
    return value if isinstance(value,list) else [value]

def calls(definition):
    result=set()
    for state in definition['States'].values():
        if state['Type']!='Task':continue
        fields=state['Resource'].split(':');service,operation=fields[-2:]
        service={'sfn':'states'}.get(service,service)
        if service=='dynamodb' and operation=='transactWriteItems':
            names={'Put':'PutItem','Update':'UpdateItem','Delete':'DeleteItem','ConditionCheck':'ConditionCheckItem'}
            for item in state['Arguments']['TransactItems']:
                require(len(item)==1,'Ambiguous transaction operation')
                result.add('dynamodb:'+names[next(iter(item))])
        else:result.add(service+':'+operation[0].upper()+operation[1:])
    return result

def verify(resources):
    role_calls={'runtime_orchestrator':set(),'runtime_eip_writer':set()}
    for key in ('day_open','ready_check','day_close','origin_guard','od_standby'):
        definition=json.loads(resources['aws_sfn_state_machine.runtime['+json.dumps(key)+']']['definition'])
        role='runtime_eip_writer' if key=='origin_guard' else 'runtime_orchestrator'
        role_calls[role]|=calls(definition)
        if key=='ready_check':require(all(a.startswith(('dynamodb:Get','scheduler:Get','ec2:Describe','rds:Describe','ecs:Describe','autoscaling:Describe')) for a in calls(definition)),'Ready-check acquired write behavior')
        if key!='origin_guard':require('ec2:AssociateAddress' not in calls(definition),'EIP writer escaped origin-guard')
    wildcard_reads={'autoscaling:DescribeAutoScalingGroups','ec2:DescribeInstances','ec2:DescribeAddresses','ec2:DescribeNetworkInterfaceAttribute','ecs:DescribeTaskDefinition','ssm:DescribeInstanceInformation','ssm:GetCommandInvocation'}
    report={}
    for role,required in role_calls.items():
        policy=json.loads(resources['aws_iam_role_policy.'+role]['policy'])
        grants=set()
        for statement in policy['Statement']:
            actions=set(listify(statement['Action']));grants|=actions
            require(statement['Effect']=='Allow' and not any('*' in a for a in actions),'Wildcard or unexpected action')
            scope=listify(statement['Resource'])
            if '*' in scope:require(actions<=wildcard_reads,'Resource-star write or scopeable action')
            if actions&{'dynamodb:PutItem','dynamodb:DeleteItem'}:
                keys=statement['Condition']['ForAllValues:StringLike']['dynamodb:LeadingKeys']
                require('mode' not in keys and 'maintenance' not in keys and 'standby-hold' not in keys,'Workflow can overwrite operator controls')
            if 'ssm:SendCommand' in actions:
                require(all('AWS-RunShellScript' not in x for x in scope),'Arbitrary shell document granted')
            if 'ec2:ModifyNetworkInterfaceAttribute' in actions:
                c=statement['Condition']
                require(c['StringEquals']['ec2:Attribute/AssociatePublicIpAddress']==['true','false'] and c['Null']['ec2:Attribute/AssociatePublicIpAddress']=='false','ENI attribute restriction changed')
            if 'ec2:AssociateAddress' in actions:
                require(role=='runtime_eip_writer','Another runtime role writes EIP')
                if any(x.endswith('instance/*') for x in scope):
                    c=statement['Condition']['StringEquals']
                    require(c['ec2:InstanceMarketType']=='spot' and c['ec2:InstanceProfile'].endswith(':instance-profile/ec-portfolio-demo-ecs-spot'),'Spot association scope broadened')
        require(grants==required,'Action/call mismatch '+role+': missing='+str(sorted(required-grants))+' unused='+str(sorted(grants-required)))
        report[role]={'calls':sorted(required),'grants':sorted(grants),'exact_action_set':True}
    event=json.loads(resources['aws_iam_role_policy.runtime_events']['policy'])
    require(len(event['Statement'])==1 and event['Statement'][0]['Action']=='states:StartExecution','Events role expanded')
    require(len(event['Statement'][0]['Resource'])==2,'Events target scope expanded')
    return {'status':'PASS','kind':'OFFLINE SOURCE CONTRACT','actual_aws_api_calls':0,'roles':report,
            'live_iam_simulation':'NOT RUN / NOT VERIFIED'}

def verify_grants(resources,grants,context):
    """P3-c0: the scheduler role starts exactly what the schedules target, and the alert topic accepts exactly
    the rules that target it. Both documents keep the legacy statements as they were."""
    role=json.loads(grants['aws_iam_role_policy.scheduler_runtime_control']['policy'])['Statement']
    require([s.get('Sid') for s in role]==['ControlDemoEc2','ControlDemoRds','StartRuntimeWorkflows'],'Scheduler statements changed')
    instance=context['aws_instance']['demo']['arn'];database=context['aws_db_instance']['demo']['arn']
    require(role[0]=={'Sid':'ControlDemoEc2','Effect':'Allow','Action':['ec2:StartInstances','ec2:StopInstances'],'Resource':instance},'Legacy EC2 statement changed')
    require(role[1]=={'Sid':'ControlDemoRds','Effect':'Allow','Action':['rds:StartDBInstance','rds:StopDBInstance'],'Resource':database},'Legacy RDS statement changed')
    start=role[2]
    targets=sorted(v['target'][0]['arn'] for k,v in resources.items() if k.startswith('aws_scheduler_schedule.runtime_orchestration['))
    require(len(targets)==4 and len(set(targets))==4,'Scheduled workflow targets')
    require(set(start)=={'Sid','Effect','Action','Resource'} and start['Effect']=='Allow' and start['Action']=='states:StartExecution','Scheduler start action')
    require(sorted(start['Resource'])==targets and not any('*' in r for r in start['Resource']),'Scheduler may start a workflow no schedule targets')
    require(not any(r.endswith(':ec-portfolio-demo-od-standby') for r in start['Resource']),'Scheduler may start od-standby')
    topic=context['aws_sns_topic']['alerts']['arn']
    rule_arn={v['name']:v['arn'] for v in context['aws_cloudwatch_event_rule'].values()}
    notifying=sorted(rule_arn[v['rule']] for k,v in resources.items() if k.startswith('aws_cloudwatch_event_target.') and v['arn']==topic)
    require(len(notifying)==2,'Rules that notify the topic')
    statements=json.loads(grants['aws_sns_topic_policy.alerts']['policy'])['Statement']
    require([s.get('Sid') for s in statements]==['AllowBudgetNotifications','AllowSchedulerAlarmNotifications','AllowRuntimeOrchestrationNotifications'],'Topic statements changed')
    require([s['Principal'] for s in statements[:2]]==[{'Service':'budgets.amazonaws.com'},{'Service':'cloudwatch.amazonaws.com'}],'Legacy topic principals changed')
    events=statements[2]
    require(events['Principal']=={'Service':'events.amazonaws.com'} and events['Action']=='sns:Publish' and events['Resource']==topic,'Events statement principal or action')
    require(events['Condition']['StringEquals']=={'aws:SourceAccount':context['data']['aws_caller_identity']['current']['account_id']},'Events statement account')
    require(sorted(events['Condition']['ArnEquals']['aws:SourceArn'])==notifying,'Events statement accepts a rule that does not notify the topic')
    return {'scheduler_start':targets,'topic_sources':notifying,'legacy_statements_unchanged':True}

if __name__=='__main__':
    spec=importlib.util.spec_from_file_location('source_export',DEMO/'scripts/cold-standby-plan-export.py')
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    resources=module.export(module.fixture_context())['resources']
    report=verify(resources)
    grants=module.export_grants(module.fixture_context())['resources'];context=module.complete_context(module.fixture_context())
    report['p3c0_grants']=verify_grants(resources,grants,context)
    # Each widening of either grant must be refused by the contract above.
    def widened(address,edit):
        copy=json.loads(json.dumps(grants));document=json.loads(copy[address]['policy']);edit(document['Statement']);copy[address]['policy']=json.dumps(document);return copy
    role,topic='aws_iam_role_policy.scheduler_runtime_control','aws_sns_topic_policy.alerts'
    standby='arn:aws:states:ap-northeast-1:000000000000:stateMachine:ec-portfolio-demo-od-standby'
    negatives=[widened(role,lambda s:s[2]['Resource'].append(standby)),widened(role,lambda s:s[2].update(Resource=s[2]['Resource'][:3])),
               widened(role,lambda s:s[2].update(Action=['states:StartExecution','states:StopExecution'])),widened(role,lambda s:s[2].update(Resource=['*'])),
               widened(role,lambda s:s[0]['Action'].append('ec2:TerminateInstances')),widened(role,lambda s:s.insert(2,dict(s[2],Sid='Extra'))),
               widened(topic,lambda s:s[2]['Condition']['ArnEquals']['aws:SourceArn'].append('arn:aws:events:ap-northeast-1:000000000000:rule/ec-portfolio-demo-origin-guard-signals')),
               widened(topic,lambda s:s[2].update(Principal='*')),widened(topic,lambda s:s[2]['Condition'].update(StringEquals={'aws:SourceAccount':'111111111111'})),
               widened(topic,lambda s:s[0].update(Principal={'Service':'events.amazonaws.com'}))]
    refused=0
    for case in negatives:
        try:verify_grants(resources,case,context)
        except (ValueError,KeyError,TypeError):refused+=1
    require(refused==len(negatives),'A widened grant passed the contract')
    report['p3c0_grants']['widening_refused']=str(refused)+'/'+str(len(negatives))
    print(json.dumps(report,indent=2))
