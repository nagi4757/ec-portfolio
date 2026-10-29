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

if __name__=='__main__':
    spec=importlib.util.spec_from_file_location('source_export',DEMO/'scripts/cold-standby-plan-export.py')
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    print(json.dumps(verify(module.export(module.fixture_context())['resources']),indent=2))
