#!/usr/bin/env python3
"""Reproducible ASL sources. Offline only: writes the five local JSON templates.
No AWS SDK, credentials, subprocess or network. JSONata uses the official evaluator in tests.
"""
import copy
import json
from pathlib import Path
D = Path(__file__).resolve().parent.parent / 'state-machines'
E = lambda x: '{% ' + x + ' %}'
S = lambda x: {'S': x}
N = lambda x: {'N': E('$string(' + x + ')')}
TABLE = '${table_name}'
MODE_STATES = ['off','spot-active','failover-prep','od-active','failback','day-close','degraded']
ARM = "$exists($mode.pk.S) and $mode.enabled.BOOL = true and $mode.scope.S in ['production','rehearsal'] and $type($mode.approvalRef.S) = 'string' and $length($trim($mode.approvalRef.S)) > 0 and $maintenance = false and (($mode.scope.S = 'production' and $request.trigger in ['scheduler','event','manual'] and $not($exists($mode.armedUntil))) or ($mode.scope.S = 'rehearsal' and $request.trigger = 'manual' and $type($mode.armedUntil.S) = 'string' and $contains($mode.armedUntil.S, /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$/) and $toMillis($mode.armedUntil.S) > $millis() and $toMillis($mode.armedUntil.S) - $millis() <= ${rehearsal_arming_max_ms}))"
ARM_COND = 'attribute_exists(enabled) AND enabled = :yes AND #scope = :scope AND approvalRef = :approval AND (#scope = :production OR (#scope = :rehearsal AND armedUntil = :armedUntil AND armedUntil > :nowUtc)) AND #state IN ('
LEASE_COND = '#owner = :owner AND lockToken = :token AND expiresAt > :minExpiry AND writeUntil = :writeUntil AND writeUntil > :now AND redriveCount = :zero'
READ_RETRY = [{'ErrorEquals':['States.TaskFailed'],'IntervalSeconds':2,'MaxAttempts':2,'BackoffRate':2}]
class Build:
 def __init__(self,name):
  self.name=name; self.s={}
  self.add('ReadMode',{'Type':'Task','Resource':'arn:aws:states:::dynamodb:getItem','Arguments':{'TableName':TABLE,'Key':{'pk':S('mode')},'ConsistentRead':True},'Assign':{'request':E('$states.input'),'mode':E('$exists($states.result.Item) ? $states.result.Item : {}')},'Next':'ReadMaintenance'})
  self.add('ReadMaintenance',{'Type':'Task','Resource':'arn:aws:states:::dynamodb:getItem','Arguments':{'TableName':TABLE,'Key':{'pk':S('maintenance')},'ConsistentRead':True},'Assign':{'maintenance':E('$exists($states.result.Item.pk.S)')},'Next':'ArmGate'})
  self.choice('ArmGate',[(ARM,'Init')],'NotArmed')
  self.add('Init',{'Type':'Pass','Assign':{'token':E('$uuid()'),'runKey':E("$request.trigger='event' and $type($request.event.id)='string' ? $request.event.id : $request.scheduledTime"),'startedAt':E('$millis()'),'writeUntil':E('$toMillis($states.context.Execution.StartTime) + ${write_window_ms}'),'redrive':E('$exists($states.context.Execution.RedriveCount) ? $states.context.Execution.RedriveCount : 0'),'polls':0,'attempts':0,'rdsWaitUntil':0,'odBootAt':0,'outcome':'ok','failure':'Runtime.Failed','target':'','holder':'','liveSha':'','tdArn':'','commandId':'','event':E('$exists($request.event) ? $request.event : {}'),'nowJst':E("$fromMillis($millis(), '[Y0001]-[M01]-[D01]T[H01]:[m01]:[s01]', '+0900')"),'dayKey':E("'day#' & $fromMillis($millis(), '[Y0001]-[M01]-[D01]', '+0900')")},'Next':'ValidateInput'})
  valid = r"$request.trigger in ['scheduler','event','manual'] and $type($request.scheduledTime) = 'string' and $length($request.scheduledTime) > 0 and $length($request.scheduledTime) < 512 and $redrive = 0 and $millis() < $writeUntil and ($request.trigger = 'manual' or ($contains($request.scheduledTime, /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,9})?Z$/) and $toMillis($states.context.Execution.StartTime) - $toMillis($request.scheduledTime) >= -60000 and $toMillis($states.context.Execution.StartTime) - $toMillis($request.scheduledTime) <= 1200000))"
  valid += " and ($request.trigger!='event' or ($type($request.event.id)='string' and $length($request.event.id)>0 and $length($request.event.id)<=128))"
  self.choice('ValidateInput',[(valid,'ReadLegacyRdsStart')],'BadInput')
  self.legacy()
  self.fail('NotArmed','NotArmed','Arming, approval, expiry, trigger or maintenance check failed; no write occurred.')
  self.fail('BadInput','BadInput','Invalid, redriven or stale input; no write occurred.')
  self.fail('InterlockFailed','Legacy.Interlock','Legacy schedule contract differs; no runtime write permitted.')
  self.fail('Failed','Runtime.Failed','A task, invariant, lease, readiness or timeout failed. Inspect execution history; independent backstops remain required.')
  self.add('Done',{'Type':'Succeed'})
  self.add('Failure',{'Type':'Pass','Assign':{'outcome':'failed'},'Next':'Release'})
  self.release('Release','EndChoice')
  self.choice('EndChoice',[("$outcome = 'ok'",'Done')],'Failed')
 def add(self,n,d):
  assert n not in self.s,n
  if d['Type']=='Task':
   d.setdefault('TimeoutSeconds',60)
   d.setdefault('Catch',[{'ErrorEquals':['States.ALL'],'Next':'Failed'}])
  self.s[n]=d
 def fail(self,n,error,cause):self.add(n,{'Type':'Fail','Error':error,'Cause':cause})
 def choice(self,n,choices,default):self.add(n,{'Type':'Choice','Choices':[{'Condition':E(c),'Next':v} for c,v in choices],'Default':default})
 def wait(self,n,seconds,nxt):self.add(n,{'Type':'Wait','Seconds':seconds,'Next':nxt})
 def read(self,n,service,op,args,nxt,assign=None):
  z={'Type':'Task','Resource':f'arn:aws:states:::aws-sdk:{service}:{op}','Arguments':args,'Next':nxt,'Retry':copy.deepcopy(READ_RETRY)}
  if service=='dynamodb' and op=='getItem':z['Resource']='arn:aws:states:::dynamodb:getItem'
  if assign:z['Assign']=assign
  self.add(n,z)
 def legacy(self):
  specs=[('RdsStart','rds-start','DISABLED','cron(50 9 ? * MON-FRI *)','ENABLED'),('Ec2Start','ec2-start','DISABLED','cron(0 10 ? * MON-FRI *)','ENABLED'),('Ec2Stop','ec2-stop','ENABLED','cron(15 0-6,22-23 * * ? *)','ENABLED'),('RdsStop','rds-stop','ENABLED','cron(30 22 ? * MON-FRI *)','ENABLED')]
  for i,(tag,suffix,state,cron,oldstate) in enumerate(specs):
   self.read('ReadLegacy'+tag,'scheduler','getSchedule',{'GroupName':'${scheduler_group_name}','Name':'${name_prefix}-'+suffix},'ReadLegacy'+specs[i+1][0] if i<3 else 'LegacyInterlock',{'legacy'+tag:E('$states.result')})
  cond=[]
  for tag,suffix,state,cron,oldstate in specs:
   old={'ec2-stop':'cron(0 17 ? * MON-FRI *)','rds-stop':'cron(10 17 ? * MON-FRI *)'}.get(suffix,cron)
   cond.append(f"($mode.scope.S = 'production' ? ($legacy{tag}.State = '{state}' and $legacy{tag}.ScheduleExpression = '{cron}') : ($legacy{tag}.State = '{oldstate}' and $legacy{tag}.ScheduleExpression = '{old}')) and $legacy{tag}.ScheduleExpressionTimezone = 'Asia/Tokyo' and $legacy{tag}.FlexibleTimeWindow.Mode = 'OFF'")
  self.choice('LegacyInterlock', [(' and '.join('('+x+')' for x in cond) + " and ($mode.scope.S='production' or ($request.trigger='manual' and $fromMillis($millis(),'[H01]:[m01]','+0900')>='17:40' and $fromMillis($millis(),'[H01]:[m01]','+0900')<'21:30'))",'Begin')],'InterlockFailed')
 def modecheck(self,modes):
  vals={':yes':{'BOOL':True},':scope':S(E('$mode.scope.S')),':approval':S(E('$mode.approvalRef.S')),':production':S('production'),':rehearsal':S('rehearsal'),':armedUntil':S(E("$exists($mode.armedUntil.S) ? $mode.armedUntil.S : ''")),':nowUtc':S(E('$fromMillis($millis())'))}
  vals.update({':currentRedrive':N('$exists($states.context.Execution.RedriveCount) ? $states.context.Execution.RedriveCount : 0'),':zero':{'N':'0'},':writeUntil':N('$writeUntil'),':nowMs':N('$millis()')})
  for i,m in enumerate(modes):vals[':s'+str(i)]=S(m)
  return {'ConditionCheck':{'TableName':TABLE,'Key':{'pk':S('mode')},'ConditionExpression':ARM_COND+', '.join(':s'+str(i) for i in range(len(modes)))+') AND :currentRedrive = :zero AND :writeUntil > :nowMs','ExpressionAttributeNames':{'#scope':'scope','#state':'state'},'ExpressionAttributeValues':vals}}
 def fence(self,label,modes=MODE_STATES,hold=False):
  tx=[{'ConditionCheck':{'TableName':TABLE,'Key':{'pk':S('maintenance')},'ConditionExpression':'attribute_not_exists(pk)'}},self.modecheck(modes),{'Update':{'TableName':TABLE,'Key':{'pk':S('lock#runtime')},'UpdateExpression':'SET lastWrite = :label, lastWriteAt = :now','ConditionExpression':LEASE_COND,'ExpressionAttributeNames':{'#owner':'owner'},'ExpressionAttributeValues':{':owner':S(E('$states.context.Execution.Id')),':token':S(E('$token')),':minExpiry':N('$millis() + ${write_margin_ms}'),':writeUntil':N('$writeUntil'),':now':N('$millis()'),':zero':{'N':'0'},':label':S(label)}}}]
  if hold:tx.append({'ConditionCheck':{'TableName':TABLE,'Key':{'pk':S('standby-hold')},'ConditionExpression':'attribute_not_exists(pk)'}})
  return tx
 def txn(self,n,tx,nxt,catch='Failure'):
  self.add(n,{'Type':'Task','Comment':'Atomic arming/mode/maintenance and lease fence; TTL is never authorization.','Resource':'arn:aws:states:::aws-sdk:dynamodb:transactWriteItems','Arguments':{'TransactItems':tx},'Catch':[{'ErrorEquals':['States.ALL'],'Next':catch}],'Next':nxt})
 def control(self,n,operation,nxt,modes=MODE_STATES,hold=False):
  tx=self.fence(n,modes,hold)
  if operation and 'Update' in operation and operation['Update']['Key']['pk']==S('mode'):
   check=tx[1]['ConditionCheck']; up=operation['Update']; up['ConditionExpression']=check['ConditionExpression'];up['ExpressionAttributeNames']={**check['ExpressionAttributeNames'],**up.get('ExpressionAttributeNames',{})};up['ExpressionAttributeValues']={**check['ExpressionAttributeValues'],**up.get('ExpressionAttributeValues',{})};tx[1]=operation
  elif operation:tx.append(operation)
  self.txn(n,tx,nxt)
  self.s[n]['Arguments']['TransactItems'][2]['Update']['ConditionExpression'] += ' AND :currentRedrive = :zero'
  self.s[n]['Arguments']['TransactItems'][2]['Update']['ExpressionAttributeValues'][':currentRedrive'] = N('$exists($states.context.Execution.RedriveCount) ? $states.context.Execution.RedriveCount : 0')
 def modewrite(self,n,state,nxt,modes=MODE_STATES):
  self.control(n,{'Update':{'TableName':TABLE,'Key':{'pk':S('mode')},'UpdateExpression':'SET #state = :newState, updatedAt = :updated','ExpressionAttributeValues':{':newState':S(state),':updated':N('$millis()')}}},nxt,modes)
 def bootstrap(self,nxt,modes=MODE_STATES):
  now=N('$millis()')
  tx=[{'ConditionCheck':{'TableName':TABLE,'Key':{'pk':S('maintenance')},'ConditionExpression':'attribute_not_exists(pk)'}},self.modecheck(modes),{'Put':{'TableName':TABLE,'Item':{'pk':S(E("'run#"+self.name+"#' & $runKey")),'owner':S(E('$states.context.Execution.Id')),'startedAt':N('$startedAt'),'writeUntil':N('$writeUntil'),'redriveCount':{'N':'0'},'ttl':N('$floor($millis()/1000)+3024000')},'ConditionExpression':'attribute_not_exists(pk)'}},self.lockput()]
  self.choice('BootstrapGate',[("($exists($states.context.Execution.RedriveCount) ? $states.context.Execution.RedriveCount : 0) = 0 and $redrive = 0 and $millis() < $writeUntil",'Bootstrap')],'Failed')
  self.txn('Bootstrap',tx,nxt,'BootstrapBusy')
  self.choice('BootstrapBusy',[("$millis() < $startedAt + "+('2700000' if self.name=='day-close' else '120000'), 'WaitLease')],'Failed')
  self.wait('WaitLease',20,'BootstrapGate')
 def lockput(self):
  return {'Put':{'TableName':TABLE,'Item':{'pk':S('lock#runtime'),'owner':S(E('$states.context.Execution.Id')),'lockToken':S(E('$token')),'expiresAt':N('$millis()+${lease_ms}'),'writeUntil':N('$writeUntil'),'redriveCount':{'N':'0'},'ttl':N('$floor(($millis()+${lease_ms})/1000)+604800')},'ConditionExpression':'attribute_not_exists(pk) OR expiresAt < :now','ExpressionAttributeValues':{':now':N('$millis()')}}}
 def reacquire(self,n,nxt,modes=MODE_STATES):
  self.txn(n,[{'ConditionCheck':{'TableName':TABLE,'Key':{'pk':S('maintenance')},'ConditionExpression':'attribute_not_exists(pk)'}},self.modecheck(modes),self.lockput()],nxt,'Failed')
 def release(self,n,nxt):
  tx=self.fence('Release')
  # A transaction cannot update and delete the same item: replace lease update with conditional delete.
  lock=tx[2]['Update'];lock['ConditionExpression']=LEASE_COND;lock.pop('UpdateExpression');lock['ExpressionAttributeValues'].pop(':label');tx[2]={'Delete':lock}
  tx[2]['Delete']['ConditionExpression'] += ' AND :currentRedrive = :zero'
  tx[2]['Delete']['ExpressionAttributeValues'][':currentRedrive'] = N('$exists($states.context.Execution.RedriveCount) ? $states.context.Execution.RedriveCount : 0')
  self.txn(n,tx,nxt,'Failed')
 def write(self,n,service,op,args,nxt,modes=MODE_STATES,hold=False,assign=None,catch='Failure'):
  self.control('Fence'+n,None,n,modes,hold)
  z={'Type':'Task','Resource':f'arn:aws:states:::aws-sdk:{service}:{op}','Arguments':args,'Next':nxt,'Catch':[{'ErrorEquals':['States.ALL'],'Next':catch}]}
  if assign:z['Assign']=assign
  self.add(n,z)
 def snapshot(self,start,nxt,prefix=''):
  a=lambda x:prefix+x
  self.read(start,'autoscaling','describeAutoScalingGroups',{'AutoScalingGroupNames':['${asg_name}']},a('ReadInstances'),{'group':E('$states.result.AutoScalingGroups[0]')})
  self.read(a('ReadInstances'),'ec2','describeInstances',{'InstanceIds':E("$append(['${od_instance_id}'], $exists($group.Instances) ? $group.Instances.InstanceId : [])")},a('ReadAddress'),{'instances':E('$append([], $states.result.Reservations.Instances)')})
  self.read(a('ReadAddress'),'ec2','describeAddresses',{'AllocationIds':['${eip_allocation_id}']},a('ReadAssociationInstance'),{'addresses':E('$states.result.Addresses'),'holder':E("$exists($states.result.Addresses[0].InstanceId) ? $states.result.Addresses[0].InstanceId : ''")})
  self.read(a('ReadAssociationInstance'),'ec2','describeInstances',{'InstanceIds':E("$distinct($append($append(['${od_instance_id}'], $exists($group.Instances) ? $group.Instances.InstanceId : []), $holder!='' ? [$holder] : []))")},a('ReadAssociationRecord'),{'instances':E('$append([], $states.result.Reservations.Instances)')})
  self.read(a('ReadAssociationRecord'),'dynamodb','getItem',{'TableName':TABLE,'Key':{'pk':S(E("'instance#' & $holder"))},'ConsistentRead':True},a('ReadOdAttribute'),{'holderRecord':E('$exists($states.result.Item) ? $states.result.Item : {}')})
  self.read(a('ReadOdAttribute'),'ec2','describeNetworkInterfaceAttribute',{'NetworkInterfaceId':'${od_eni_id}','Attribute':'associatePublicIpAddress'},a('ReadRds'),{'odPublic':E('$states.result.AssociatePublicIpAddress')})
  self.read(a('ReadRds'),'rds','describeDBInstances',{'DbInstanceIdentifier':'${db_instance_identifier}'},a('ReadService'),{'db':E('$states.result.DbInstances[0]')})
  self.read(a('ReadService'),'ecs','describeServices',{'Cluster':'${ecs_cluster_arn}','Services':['${ecs_service_name}']},a('ReadTaskDefinition'),{'service':E('$states.result.Services[0]'),'tdArn':E('$states.result.Services[0].TaskDefinition')})
  self.read(a('ReadTaskDefinition'),'ecs','describeTaskDefinition',{'TaskDefinition':E('$tdArn')},a('SnapshotGate'),{'liveSha':E("($images := $states.result.TaskDefinition.ContainerDefinitions[Name='api'].Image; $count($images)=1 and $substringBefore($images[0], ':') = '${expected_image_repository}' ? $substringAfter($images[0], ':') : '')")})
  valid="$group.AutoScalingGroupName = '${asg_name}' and $group.MinSize = 0 and $group.MaxSize = 2 and $group.CapacityRebalance = false and $count($group.Instances) <= 2 and $count($addresses) = 1 and $addresses[0].AllocationId = '${eip_allocation_id}' and ($holder = '' or $holder = '${od_instance_id}' or $holder in $group.Instances.InstanceId or ($holderRecord.asg.S='${asg_name}' and $instances[InstanceId=$holder][0].IamInstanceProfile.Arn='${spot_instance_profile_arn}' and $instances[InstanceId=$holder][0].InstanceLifecycle='spot' and $instances[InstanceId=$holder][0].State.Name in ['terminated','shutting-down','stopped'])) and $count($instances[InstanceId='${od_instance_id}' and IamInstanceProfile.Arn='${od_instance_profile_arn}'])=1 and $db.DbInstanceIdentifier = '${db_instance_identifier}' and $service.ServiceName = '${ecs_service_name}' and $contains($liveSha, /^[a-f0-9]{40}$/)"
  self.choice(a('SnapshotGate'),[(valid,nxt)],'Failed')
 def local_smoke(self,n,target,doc,nxt,mode='local'):
  self.write(n,'ssm','sendCommand',{'DocumentName':doc,'DocumentVersion':'1','InstanceIds':[E(target)],'TimeoutSeconds':300,'Parameters':{'expectedImageSha':[E('$liveSha')],'expectedImageRepository':['${expected_image_repository}'],'expectedTaskDefinitionArn':[E('$tdArn')],'checkMode':[mode],'cloudFrontDomain':['${cloudfront_domain}']}},n+'Wait',assign={'commandId':E('$states.result.Command.CommandId'),'polls':0})
  self.wait(n+'Wait',10,n+'Read')
  self.read(n+'Read','ssm','getCommandInvocation',{'CommandId':E('$commandId'),'InstanceId':E(target)},n+'Choice',{'commandStatus':E('$states.result.Status'),'commandCode':E('$states.result.ResponseCode'),'polls':E('$polls+1')})
  self.choice(n+'Choice',[("$commandStatus = 'Success' and $commandCode = 0",nxt),("$commandStatus in ['Pending','InProgress','Delayed'] and $polls < 36",n+'Wait')],'Failure')
 def attest(self,n,nxt):
  self.control(n,{'Put':{'TableName':TABLE,'Item':{'pk':S(E("'ready#' & $target")),'instanceId':S(E('$target')),'sha':S(E('$liveSha')),'taskDefinition':S(E('$tdArn')),'readyAt':N('$millis()'),'validUntil':N('$millis()+600000'),'ttl':N('$floor($millis()/1000)+86400')}}},nxt)
 def child(self,n,arn,payload,nxt,modes=MODE_STATES):
  inp={'trigger':'manual','scheduledTime':E("'manual-' & $states.context.Execution.Id & '-"+n+"'"),**payload}
  self.write(n,'sfn','startExecution',{'StateMachineArn':arn,'Input':E('$string('+json.dumps(inp,separators=(',',':'))+')') if False else inp},nxt,modes)
  # SDK StartExecution.Input is a JSON string, not an object. Build JSONata string with safely serialized literal/variable entries.
  pairs=[]
  for k,v in inp.items():pairs.append(json.dumps(k)+':'+(v[3:-3] if isinstance(v,str) and v.startswith('{% ') else json.dumps(v)))
  self.s[n]['Arguments']['Input']=E('$string({'+','.join(pairs)+'})')
 def finish(self):
  # Compile public write-state edges through their dedicated fence, then verify the resulting graph in tests.
  harden(self)
  for n,state in self.s.items():
   for edge in ['Next','Default']:
    if state.get(edge) in self.s and ('Fence'+state[edge]) in self.s and n != 'Fence'+state[edge]:state[edge]='Fence'+state[edge]
   for edge in state.get('Choices',[])+state.get('Catch',[]):
    if ('Fence'+edge['Next']) in self.s and n!='Fence'+edge['Next']:edge['Next']='Fence'+edge['Next']
  # A Redrive resumes a failed Task itself, so the Task's Arguments also assert redrive/window before any external SDK request.
  def literal(x):
   if isinstance(x,str) and x.startswith('{% '):return x[3:-3]
   if isinstance(x,list):return '['+','.join(literal(v) for v in x)+']'
   if isinstance(x,dict):return '{'+','.join(json.dumps(k)+':'+literal(v) for k,v in x.items())+'}'
   return json.dumps(x)
  for state in self.s.values():
   resource=state.get('Resource','');op=resource.split(':')[-1]
   if resource.startswith('arn:aws:states:::aws-sdk:') and not op.startswith(('get','describe','list','batchGet')) and op!='transactWriteItems':
    key=next(iter(state['Arguments']));original=state['Arguments'][key]
    state['Arguments'][key]=E("($assert(($exists($states.context.Execution.RedriveCount) ? $states.context.Execution.RedriveCount : 0)=0 and $millis()<$writeUntil,'Redriven or expired write Task'); "+literal(original)+')')
  # AWS SDK integrations use PascalCase AttributeValue Bool; optimized DDB reads retain BOOL.
  def sdk_values(x):
   if isinstance(x,list):return [sdk_values(v) for v in x]
   if isinstance(x,dict):return {('Bool' if k=='BOOL' else k):sdk_values(v) for k,v in x.items()}
   return x
  for state in self.s.values():
   if state.get('Resource','').startswith('arn:aws:states:::aws-sdk:dynamodb:'):state['Arguments']=sdk_values(state['Arguments'])
  return {'Comment':'P3-a real disabled-runtime definition; control table is empty until a separate approved arming session. Failures never broaden targets or authorization.','QueryLanguage':'JSONata','TimeoutSeconds':'__timeout_seconds__','StartAt':'ReadMode','States':self.s}

def harden(b):
 s=b.s
 if b.name=='day-open':
  s['SpotIdentity']['Choices'][0]['Next']='RecordSpotInService'
  b.control('RecordSpotInService',{'Update':{'TableName':TABLE,'Key':{'pk':S(E("'instance#' & $target"))},'UpdateExpression':'SET firstInServiceAt = if_not_exists(firstInServiceAt, :now), asg = :asg','ExpressionAttributeValues':{':now':N('$millis()'),':asg':S('${asg_name}')}}},'SpotSmoke',['spot-active'])
  # Ready TTL remains exactly 10 minutes. Re-prove at 07:55; never hold a lease while waiting.
  s['SpotEndToEndChoice']['Choices'][0]['Next']='ReleaseRefreshWait'
  b.release('ReleaseRefreshWait','RefreshTimeChoice')
  b.choice('RefreshTimeChoice',[("$mode.scope.S='production' and $fromMillis($millis(),'[H01]:[m01]','+0900')<'07:55'",'WaitReadyRefresh')],'Done')
  b.add('WaitReadyRefresh',{'Type':'Wait','Timestamp':E("$fromMillis($toMillis($fromMillis($millis(),'[Y0001]-[M01]-[D01]','+0900') & 'T07:55:00+09:00'))"),'Next':'RefreshSnapshot'})
  b.snapshot('RefreshSnapshot','RefreshHolderGate','Refresh')
  b.choice('RefreshHolderGate',[("$holder=$target and $mode.state.S='off'",'ReacquireRefresh'),("$holder=$target",'ReacquireRefresh')],'Failed')
  # The mode condition is read fresh in ReacquireRefresh, not the initial mode variable.
  b.reacquire('ReacquireRefresh','RefreshReadySmoke',['spot-active'])
  b.local_smoke('RefreshReadySmoke','$target','${spot_smoke_document_name}','RefreshReadyAttest')
  b.attest('RefreshReadyAttest','Release')
  # Every successful smoke still has to fit the original 07:50 opening deadline.
  s['SpotSmokeChoice']['Choices'][0]['Next']='OpeningDeadline'
  b.choice('OpeningDeadline',[("$mode.scope.S='rehearsal' or $fromMillis($millis(),'[H01]:[m01]','+0900')<'07:50'",'AttestSpot')],'OpenMissed')
 if b.name=='origin-guard':
  # Signals for measurement/foreign hosts and rebalance do not start OD.
  s['SnapshotGate']['Choices'][0]['Next']='SignalChoice'
  sig="$request.trigger='event' and (($event.source='aws.ec2' and $event.\"detail-type\" in ['EC2 Spot Instance Interruption Warning','EC2 Instance Rebalance Recommendation'] and $event.detail.\"instance-id\" in $group.Instances.InstanceId) or ($event.source='aws.autoscaling' and $event.\"detail-type\"='EC2 Instance-terminate Lifecycle Action' and $event.detail.AutoScalingGroupName='${asg_name}' and $event.detail.EC2InstanceId in $group.Instances.InstanceId))"
  b.choice('SignalChoice',[(sig,'SetSignal'),("$request.trigger='event' and $event.source in ['aws.ec2','aws.autoscaling'] and $not($event.source='aws.ec2' and $event.\"detail-type\"='EC2 Instance State-change Notification' and $event.detail.\"instance-id\"='${od_instance_id}')",'Done')],'IntentChoice')
  b.add('SetSignal',{'Type':'Pass','Assign':{'dispatch':'signal','signalTarget':E("$event.source='aws.ec2' ? $event.detail.\"instance-id\" : $event.detail.EC2InstanceId"),'signalField':E("$event.\"detail-type\"='EC2 Instance Rebalance Recommendation' ? 'rebalanceAt' : ($event.source='aws.ec2' ? 'interruptionAt' : 'terminatingAt')")},'Next':'BootstrapGate'})
  s['Dispatch']['Choices'].insert(0,{'Condition':E("$dispatch='signal'"),'Next':'RecordSignal'})
  b.control('RecordSignal',{'Update':{'TableName':TABLE,'Key':{'pk':S(E("'instance#' & $signalTarget"))},'UpdateExpression':'SET #signal = :now','ExpressionAttributeNames':{'#signal':E('$signalField')},'ExpressionAttributeValues':{':now':N('$millis()')}}},'SignalDispatch')
  b.choice('SignalDispatch',[("$signalTarget=$holder and $signalField in ['interruptionAt','terminatingAt'] and $mode.state.S in ['spot-active','degraded']",'Prepare')],'Release')
  # Reconciliation delegates a fresh real host smoke, allowing subsequent ready-check and health decisions.
  old=s['Reconcile']['Choices'][2];old['Next']='BootstrapRefresh'
  b.add('BootstrapRefresh',{'Type':'Pass','Assign':{'dispatch':'refresh'},'Next':'BootstrapGate'})
  s['Dispatch']['Choices'].insert(0,{'Condition':E("$dispatch='refresh'"),'Next':'RefreshHolder'})
  b.child('RefreshHolder','${od_standby_arn}',{'action':'supervise','reason':'guard-health'},'Release')
  # Refresh all policy inputs after taking the lease, then again after the stability wait.
  s['Dispatch']['Default']='WaitStable';s['WaitStable']['Seconds']=60
  s['ReReadTarget']['Next']='StableSnapshot'
  b.snapshot('StableSnapshot','ReadStableRecord','Stable')
  b.read('ReadStableRecord','dynamodb','getItem',{'TableName':TABLE,'Key':{'pk':S(E("'instance#' & $target"))},'ConsistentRead':True},'ReadStablePromotion',{'instanceRecord':E('$exists($states.result.Item) ? $states.result.Item : {}')})
  b.read('ReadStablePromotion','dynamodb','getItem',{'TableName':TABLE,'Key':{'pk':S('promotion')},'ConsistentRead':True},'ReadHolderReady',{'promotion':E('$exists($states.result.Item) ? $states.result.Item : {}')})
  b.read('ReadHolderReady','dynamodb','getItem',{'TableName':TABLE,'Key':{'pk':S(E("'ready#' & $holder"))},'ConsistentRead':True},'ReadHolderRecord',{'holderReady':E('$exists($states.result.Item) ? $states.result.Item : {}')})
  b.read('ReadHolderRecord','dynamodb','getItem',{'TableName':TABLE,'Key':{'pk':S(E("'instance#' & $holder"))},'ConsistentRead':True},'StablePromotionPolicy',{'holderRecord':E('$exists($states.result.Item) ? $states.result.Item : {}')})
  recovered="$request.intent='promote-od' and $holder in $group.Instances[LifecycleState='InService' and HealthStatus='Healthy'].InstanceId and $instances[InstanceId=$holder][0].State.Name='running' and $holderReady.instanceId.S=$holder and $holderReady.sha.S=$liveSha and $holderReady.taskDefinition.S=$tdArn and $number($holderReady.validUntil.N)>$millis() and $instances[InstanceId=$holder][0].InstanceLifecycle='spot' and $instances[InstanceId=$holder][0].IamInstanceProfile.Arn='${spot_instance_profile_arn}' and $exists($holderRecord.firstInServiceAt.N) and $millis()-$number($holderRecord.firstInServiceAt.N)>=60000 and $not($exists($holderRecord.interruptionAt)) and $not($exists($holderRecord.terminatingAt)) and ($not($exists($holderRecord.rebalanceAt.N)) or $number($holderRecord.rebalanceAt.N)<$millis()-1800000)"
  b.choice('StablePromotionPolicy',[(recovered,'AbortOdMode'),(s['PromotionPolicy']['Choices'][0]['Condition'][3:-3],'StableTarget')],'Failure')
  b.modewrite('AbortOdMode','spot-active','StopPreparedOd',['failover-prep'])
  b.child('StopPreparedOd','${od_standby_arn}',{'action':'stop','reason':'spot-recovered'},'Release',['spot-active'])
  # Promotion counts cannot be overwritten from a stale read or a failed prior writer.
  tx=s['FenceAssociate']['Arguments']['TransactItems']
  tx.append({'ConditionCheck':{'TableName':TABLE,'Key':{'pk':S('promotion')},'ConditionExpression':'(attribute_not_exists(pk) AND :expected = :absent) OR #at = :expectedAt','ExpressionAttributeNames':{'#at':'at'},'ExpressionAttributeValues':{':expected':{'BOOL':E('$exists($promotion.pk)')},':absent':{'BOOL':False},':expectedAt':N('$exists($promotion.at.N) ? $number($promotion.at.N) : -1')}}})
  tx.append({'ConditionCheck':{'TableName':TABLE,'Key':{'pk':S(E("'instance#' & $target"))},'ConditionExpression':'(attribute_not_exists(interruptionAt) AND attribute_not_exists(terminatingAt) AND (attribute_not_exists(rebalanceAt) OR rebalanceAt < :rebalanceBefore)) OR :target = :od','ExpressionAttributeValues':{':target':S(E('$target')),':od':S('${od_instance_id}'),':rebalanceBefore':N('$millis()-1800000')}}})
  s['SpotActive']['Next']='CleanupOdChoice'
  b.choice('CleanupOdChoice',[("$instances[InstanceId='${od_instance_id}'][0].State.Name='running'",'StopPreparedOd')],'Release')
  # A1 early-target is stopped OD, with a proved nonserving previous holder and a dedicated current-mode fence.
 if b.name=='od-standby':
  # Direct service events can prepare only the current production holder, never rebalance or arbitrary hosts.
  before=s['PrepareGate']['Choices'][0]['Condition'][3:-3]
  event="($request.trigger!='event' or ($event.source='aws.ec2' and $event.\"detail-type\"='EC2 Spot Instance Interruption Warning' and $event.detail.\"instance-id\"=$holder and $holder in $group.Instances.InstanceId) or ($event.source='aws.autoscaling' and $event.\"detail-type\"='EC2 Instance-terminate Lifecycle Action' and $event.detail.AutoScalingGroupName='${asg_name}' and $event.detail.EC2InstanceId=$holder and $holder in $group.Instances.InstanceId))"
  s['PrepareGate']['Choices'][0]['Condition']=E('('+before+') and '+event)
  s['Supervision']['Choices'].insert(0,{'Condition':E("$mode.state.S='spot-active' and $holder in $group.Instances[LifecycleState='InService' and HealthStatus='Healthy'].InstanceId and $instances[InstanceId=$holder][0].InstanceLifecycle='spot' and $instances[InstanceId=$holder][0].IamInstanceProfile.Arn='${spot_instance_profile_arn}' and $instances[InstanceId=$holder][0].State.Name='running'"),'Next':'RefreshSpotPath'})
  b.add('RefreshSpotPath',{'Type':'Pass','Assign':{'path':'refresh','target':E('$holder')},'Next':'BootstrapGate'})
  s['PathChoice']['Choices'].insert(0,{'Condition':E("$path='refresh'"),'Next':'RefreshSpotSmoke'})
  b.local_smoke('RefreshSpotSmoke','$target','${spot_smoke_document_name}','RefreshSpotAttest')
  b.attest('RefreshSpotAttest','ResetHealthFailures')
  b.control('ResetHealthFailures',{'Update':{'TableName':TABLE,'Key':{'pk':S(E("'instance#' & $target"))},'UpdateExpression':'SET healthFailures=:zero','ExpressionAttributeValues':{':zero':{'N':'0'}}}},'Release',['spot-active'])
  s['RefreshSpotSmokeChoice']['Default']='RecordHealthFailure'
  b.control('RecordHealthFailure',{'Update':{'TableName':TABLE,'Key':{'pk':S(E("'instance#' & $target"))},'UpdateExpression':'ADD healthFailures :one','ExpressionAttributeValues':{':one':{'N':'1'}}}},'ReadHealthFailures',['spot-active'])
  b.read('ReadHealthFailures','dynamodb','getItem',{'TableName':TABLE,'Key':{'pk':S(E("'instance#' & $target"))},'ConsistentRead':True},'HealthFailureChoice',{'healthRecord':E('$states.result.Item')})
  b.choice('HealthFailureChoice',[("$number($healthRecord.healthFailures.N)>=2",'RequestHealthFailover')],'Failure')
  b.child('RequestHealthFailover','${od_standby_arn}',{'action':'prepare','reason':'health-failed-twice'},'Failure',['spot-active'])
  # Initial plan/liveTD remains exact and host commands require a sufficiently new Agent for ENV_VAR interpolation.
  s['ReadSsmOnline']['Assign']['ssmOnline']=E("$count($states.result.InstanceInformationList[InstanceId='${od_instance_id}' and PingStatus='Online' and ($number($split(AgentVersion,'.')[0])>3 or ($number($split(AgentVersion,'.')[0])=3 and ($number($split(AgentVersion,'.')[1])>3 or ($number($split(AgentVersion,'.')[1])=3 and $number($split(AgentVersion,'.')[2])>=2746))))])=1")
  # Failback requires first-observed InService settle, not instance launch time.
  s['FailbackIdentityRead']['Next']='ReadFailbackRecord'
  b.read('ReadFailbackRecord','dynamodb','getItem',{'TableName':TABLE,'Key':{'pk':S(E("'instance#' & $target"))},'ConsistentRead':True},'FailbackIdentity',{'failbackRecord':E('$exists($states.result.Item) ? $states.result.Item : {}')})
  s['FailbackIdentity']['Choices'][0]['Condition']=E(s['FailbackIdentity']['Choices'][0]['Condition'][3:-3]+" and $exists($failbackRecord.firstInServiceAt.N) and $millis()-$number($failbackRecord.firstInServiceAt.N)>=900000 and $not($exists($failbackRecord.interruptionAt)) and $not($exists($failbackRecord.terminatingAt)) and ($not($exists($failbackRecord.rebalanceAt.N)) or $millis()-$number($failbackRecord.rebalanceAt.N)>1800000)")
  s['StopOd']['Assign']={'polls':0}
 if b.name=='day-close':s['StopOd']['Assign']={'polls':0}
 # Caught read errors after acquiring a lease take the conditional release path;
 # before the lease exists, its conditional delete fails without changing anything.
 if b.name!='ready-check':
  for n,state in s.items():
   if state['Type']=='Task' and state['Resource'].split(':')[-1].startswith(('describe','get')) and n not in ['ReadMode','ReadMaintenance']:
    for catch in state.get('Catch',[]):
     if catch['Next']=='Failed':catch['Next']='Failure'

 # Recovery after AssociateAddress success with a lost response: same physical holder, no second association.
 if b.name=='origin-guard':
  recovery="($holder='${od_instance_id}' and $mode.state.S in ['failover-prep','failback','degraded']) or ($holder in $group.Instances[LifecycleState='InService' and HealthStatus='Healthy'].InstanceId and $mode.state.S in ['failback','failover-prep','degraded'])"
  s['Reconcile']['Choices'].insert(0,{'Condition':E(recovery),'Next':'RecoverObserved'})
  b.add('RecoverObserved',{'Type':'Pass','Assign':{'request':E("$merge([$request, {'intent':$holder='${od_instance_id}' ? 'promote-od' : 'promote-spot','target':$holder}])"),'dispatch':'associate','target':E('$holder')},'Next':'ReadTargetReady'})
  s['Dispatch']['Choices']=[x for x in s['Dispatch']['Choices'] if x['Condition']!=E('$target=$holder')]
  s['StableTarget']['Choices'][0]['Next']='AssociationNeeded'
  b.choice('AssociationNeeded',[("$holder=$target",'RecordPromotion')],'Associate')
  # Only exact production ASG launch events contribute to the loop breaker.
  launch="$request.trigger='event' and $event.source='aws.autoscaling' and $event.\"detail-type\" in ['EC2 Instance Launch Successful','EC2 Instance Launch Unsuccessful'] and $event.detail.AutoScalingGroupName='${asg_name}'"
  s['SignalChoice']['Choices'].insert(0,{'Condition':E(launch),'Next':'LaunchSignal'})
  b.add('LaunchSignal',{'Type':'Pass','Assign':{'dispatch':'launch'},'Next':'BootstrapGate'})
  s['Dispatch']['Choices'].insert(0,{'Condition':E("$dispatch='launch'"),'Next':'ReadLaunchDay'})
  b.read('ReadLaunchDay','dynamodb','getItem',{'TableName':TABLE,'Key':{'pk':S(E('$dayKey'))},'ConsistentRead':True},'RecordLaunchDay',{'launchDay':E('$exists($states.result.Item) ? $states.result.Item : {}')})
  b.control('RecordLaunchDay',{'Update':{'TableName':TABLE,'Key':{'pk':S(E('$dayKey'))},'UpdateExpression':'SET launchWindowStart=:window, launchCount=:count, abandonCount=:abandon, ttl=:ttl','ExpressionAttributeValues':{':window':N('$exists($launchDay.launchWindowStart.N) and $number($launchDay.launchWindowStart.N)>$millis()-3600000 ? $number($launchDay.launchWindowStart.N) : $millis()'),':count':N('($exists($launchDay.launchWindowStart.N) and $number($launchDay.launchWindowStart.N)>$millis()-3600000 ? $number($launchDay.launchCount.N) : 0)+1'),':abandon':N("($exists($launchDay.launchWindowStart.N) and $number($launchDay.launchWindowStart.N)>$millis()-3600000 and $exists($launchDay.abandonCount.N) ? $number($launchDay.abandonCount.N) : 0)+($event.\"detail-type\"='EC2 Instance Launch Unsuccessful' and $contains($lowercase(($exists($event.detail.StatusMessage) ? $string($event.detail.StatusMessage) : '') & ' ' & ($exists($event.detail.Cause) ? $string($event.detail.Cause) : '')),'abandon') ? 1 : 0)"),':ttl':N('$floor($millis()/1000)+172800')}}},'Release')
 if b.name=='od-standby':
  # The 60-minute cooldown is persisted and resumed by a later tick, never a 60-minute Wait inside a 45-minute execution.
  idx=next(i for i,c in enumerate(s['Supervision']['Choices']) if c['Next']=='SelectFailback')
  s['Supervision']['Choices'][idx]['Condition']=E(s['Supervision']['Choices'][idx]['Condition'][3:-3]+" and ($not($exists($day.starts.N)) or $number($day.starts.N)<3) and ($not($exists($day.cooldownUntil.N)) or $number($day.cooldownUntil.N)=0)")
  s['Supervision']['Choices'][idx:idx]=[
   {'Condition':E("$mode.state.S='od-active' and $exists($day.cooldownUntil.N) and $number($day.cooldownUntil.N)>0 and $number($day.cooldownUntil.N)<=$millis() and $fromMillis($millis(),'[H01]:[m01]','+0900')<'21:00'"),'Next':'ResumePath'},
   {'Condition':E("$mode.state.S='od-active' and $exists($day.cooldownUntil.N) and $number($day.cooldownUntil.N)>0"),'Next':'Done'},
   {'Condition':E("$mode.state.S='od-active' and $number($day.launchWindowStart.N)>$millis()-3600000 and ($number($day.launchCount.N)>=3 or $number($day.abandonCount.N)>=2)"),'Next':'CooldownPath'}]
  for n,p in [('ResumePath','resume'),('CooldownPath','cooldown')]:b.add(n,{'Type':'Pass','Assign':{'path':p},'Next':'BootstrapGate'})
  s['PathChoice']['Choices'].insert(0,{'Condition':E("$path='cooldown'"),'Next':'RecordCooldown'})
  s['PathChoice']['Choices'].insert(0,{'Condition':E("$path='resume'"),'Next':'ResumeSpot'})
  b.control('RecordCooldown',{'Update':{'TableName':TABLE,'Key':{'pk':S(E('$dayKey'))},'UpdateExpression':'SET cooldownUntil=:until','ExpressionAttributeValues':{':until':N('$millis()+3600000')}}},'CoolSpot',['od-active'])
  b.write('CoolSpot','autoscaling','setDesiredCapacity',{'AutoScalingGroupName':'${asg_name}','DesiredCapacity':0,'HonorCooldown':False},'Release',['od-active'])
  b.write('ResumeSpot','autoscaling','setDesiredCapacity',{'AutoScalingGroupName':'${asg_name}','DesiredCapacity':1,'HonorCooldown':False},'ResetCooldown',['od-active'])
  b.control('ResetCooldown',{'Update':{'TableName':TABLE,'Key':{'pk':S(E('$dayKey'))},'UpdateExpression':'SET cooldownUntil=:zero, launchCount=:zero, abandonCount=:zero, launchWindowStart=:now','ExpressionAttributeValues':{':zero':{'N':'0'},':now':N('$millis()')}}},'Release',['od-active'])
  # Capacity errors are retried only through a new fence. Other errors fail closed.
  s['StartOd']['Catch']=[{'ErrorEquals':['Ec2.InsufficientInstanceCapacityException'],'Next':'StartRetry'},{'ErrorEquals':['States.ALL'],'Next':'Failure'}]
  b.add('StartRetry',{'Type':'Pass','Assign':{'attempts':E('$attempts+1')},'Next':'StartRetryChoice'})
  b.choice('StartRetryChoice',[("$attempts<3",'WaitStartRetry')],'Failure');b.wait('WaitStartRetry',60,'StartOd')
  # No public IPv4 after a bounded wait may use A1 only after a fresh proof that the holder no longer serves.
  s['BootChoice']['Choices'].append({'Condition':E("$od.State.Name='running' and $polls>=20"),'Next':'ReacquireA1'})
  b.reacquire('ReacquireA1','A1Snapshot',['failover-prep']);b.snapshot('A1Snapshot','A1Check','A1')

 if b.name=='origin-guard':
  # Persist first InService observation of a replacement Spot before asking OD to consider failback.
  for c in s['Dispatch']['Choices']:
   if c['Next']=='Supervise':c['Next']='ObserveCandidateChoice'
  b.choice('ObserveCandidateChoice',[("$count($group.Instances[LifecycleState='InService' and HealthStatus='Healthy'])=1",'ObserveCandidate')],'Supervise')
  b.control('ObserveCandidate',{'Update':{'TableName':TABLE,'Key':{'pk':S(E("'instance#' & $group.Instances[LifecycleState='InService' and HealthStatus='Healthy'][0].InstanceId"))},'UpdateExpression':'SET firstInServiceAt=if_not_exists(firstInServiceAt, :now), asg=:asg','ExpressionAttributeValues':{':now':N('$millis()'),':asg':S('${asg_name}')}}},'Supervise')
 if b.name=='od-standby':
  cond=s['FailbackIdentity']['Choices'][0]['Condition'][3:-3]
  s['FailbackIdentity']['Choices'][0]['Condition']=E(cond+" and $exists($candidate.PublicIpAddress) and $candidate.PublicIpAddress!=$addresses[0].PublicIp")
  for c in s['Supervision']['Choices']:
   if c['Next']=='SelectFailback':c['Condition']=E(c['Condition'][3:-3]+" and ($not($exists($day.failbackBanUntil.N)) or $number($day.failbackBanUntil.N)<=$millis())")
  # Failed end-to-end failback restores OD once, verifies holder and host, then reports failure (never promoted to success).
  s['RestoreRequest']['Next']='ReleaseRestore';b.release('ReleaseRestore','WaitRestore')
  b.wait('WaitRestore',15,'ReadRestoreAddress');b.read('ReadRestoreAddress','ec2','describeAddresses',{'AllocationIds':['${eip_allocation_id}']},'RestoredChoice',{'restoreHolder':E('$states.result.Addresses[0].InstanceId'),'attempts':E('$attempts+1')})
  b.choice('RestoredChoice',[("$restoreHolder='${od_instance_id}'",'ReacquireRestore'),("$attempts<8",'WaitRestore')],'Failed')
  b.reacquire('ReacquireRestore','RestoreOdEndToEnd',['od-active'])
  b.local_smoke('RestoreOdEndToEnd',"'${od_instance_id}'",'${od_readiness_document_name}','RestoreCooldown',mode='endToEnd')
  b.control('RestoreCooldown',{'Update':{'TableName':TABLE,'Key':{'pk':S(E('$dayKey'))},'UpdateExpression':'SET failbackBanUntil=:until','ExpressionAttributeValues':{':until':N('$millis()+3600000')}}},'Failure',['od-active'])
 # A caught failure during preparation/failback marks degraded while preserving approval, never restarts a host.
 if b.name!='ready-check':
  s['Failure']['Next']='ReadFailureMode'
  b.read('ReadFailureMode','dynamodb','getItem',{'TableName':TABLE,'Key':{'pk':S('mode')},'ConsistentRead':True},'FailureModeChoice',{'failedMode':E('$exists($states.result.Item) ? $states.result.Item : {}')})
  s['ReadFailureMode']['Catch']=[{'ErrorEquals':['States.ALL'],'Next':'Failed'}]
  b.choice('FailureModeChoice',[("$failedMode.state.S in ['failover-prep','failback']",'MarkDegraded')],'Release')
  b.modewrite('MarkDegraded','degraded','Release',['failover-prep','failback'])

 # Failure cleanup must be acyclic even if approval/lease is lost.
 if b.name!='ready-check':s['MarkDegraded']['Catch']=[{'ErrorEquals':['States.ALL'],'Next':'Release'}]
 if b.name=='day-close':
  # CloseMode deliberately precedes the lease, but a completed duplicate must not close tomorrow's mode again.
  s['CloseMode']['Arguments']['TransactItems'].append({'ConditionCheck':{'TableName':TABLE,'Key':{'pk':S(E("'run#day-close#' & $runKey"))},'ConditionExpression':'attribute_not_exists(pk)'}})
 if b.name=='day-open':
  # An interruption between initial opening and 07:55 may legitimately make OD the current origin.
  s['RefreshHolderGate']['Choices']=[{'Condition':E("$holder='${od_instance_id}' and $instances[InstanceId='${od_instance_id}'][0].State.Name='running'"),'Next':'SelectMorningOd'},{'Condition':E("$holder=$target and $holder in $group.Instances[LifecycleState='InService' and HealthStatus='Healthy'].InstanceId"),'Next':'ReacquireRefresh'}]
  b.add('SelectMorningOd',{'Type':'Pass','Assign':{'target':'${od_instance_id}'},'Next':'ReacquireMorningOd'})
  b.reacquire('ReacquireMorningOd','MorningOdReadiness',['od-active'])
  b.local_smoke('MorningOdReadiness',"'${od_instance_id}'",'${od_readiness_document_name}','MorningOdAttestation')
  b.attest('MorningOdAttestation','Release')
  # A missed opening still reports failure. Its child can prepare OD, whose genuine 07:55 proof may make 08:00 ready-check pass.
  s['OpenMissed']['Assign']={'outcome':'failed'};s['OpenMissed']['Next']='ReleaseOpenMissed'
  b.release('ReleaseOpenMissed','MissedRefreshTimeChoice')
  b.choice('MissedRefreshTimeChoice',[("$mode.scope.S='production'",'WaitReadyRefresh')],'Failed')
 if b.name=='origin-guard':
  # A valid 07:55 proof makes the 08:00 tick read-only, avoiding a needless lease collision with ready-check.
  s['SnapshotGate']['Choices'][0]['Next']='ReadTickReady'
  b.read('ReadTickReady','dynamodb','getItem',{'TableName':TABLE,'Key':{'pk':S(E("'ready#' & $holder"))},'ConsistentRead':True},'ReadTickDay',{'tickReady':E('$exists($states.result.Item) ? $states.result.Item : {}')})
  b.read('ReadTickDay','dynamodb','getItem',{'TableName':TABLE,'Key':{'pk':S(E('$dayKey'))},'ConsistentRead':True},'SignalChoice',{'tickDay':E('$exists($states.result.Item) ? $states.result.Item : {}')})
  fresh="$request.trigger='scheduler' and $tickReady.instanceId.S=$holder and $tickReady.sha.S=$liveSha and $tickReady.taskDefinition.S=$tdArn and $number($tickReady.validUntil.N)>$millis() and (($mode.state.S='spot-active' and $holder in $group.Instances[LifecycleState='InService' and HealthStatus='Healthy'].InstanceId and $instances[InstanceId=$holder][0].InstanceLifecycle='spot' and $instances[InstanceId=$holder][0].IamInstanceProfile.Arn='${spot_instance_profile_arn}' and $instances[InstanceId=$holder][0].State.Name='running' and $instances[InstanceId='${od_instance_id}'][0].State.Name='stopped') or ($mode.state.S='od-active' and $holder='${od_instance_id}' and $instances[InstanceId='${od_instance_id}'][0].State.Name='running' and $exists($tickDay.odDeadline.N) and $number($tickDay.odDeadline.N)>$millis()))"
  s['Reconcile']['Choices'].insert(0,{'Condition':E(fresh),'Next':'Done'})
 if b.name=='od-standby':
  # Without a pending eligible failback/cooldown, supervise refreshes the OD proof instead of letting it expire indefinitely.
  s['Supervision']['Choices'].append({'Condition':E("$mode.state.S='od-active' and $holder='${od_instance_id}' and $instances[InstanceId='${od_instance_id}'][0].State.Name='running'"),'Next':'FallbackOdRefresh'})
  s['FailbackIdentity']['Default']='FallbackOdRefresh'
  b.add('FallbackOdRefresh',{'Type':'Pass','Assign':{'path':'od-refresh','target':'${od_instance_id}'},'Next':'BootstrapGate'})
  s['PathChoice']['Choices'].insert(0,{'Condition':E("$path='od-refresh'"),'Next':'SuperviseOdReadiness'})
  b.local_smoke('SuperviseOdReadiness',"'${od_instance_id}'",'${od_readiness_document_name}','SuperviseOdAttestation')
  b.attest('SuperviseOdAttestation','Release')
  # Do not scale in an EIP-losing Spot before its replacement public IPv4 is present.
  for c in s['PathChoice']['Choices']:
   if c['Next']=='RecordCooldown':c['Next']='ReadCooldownGroup'
  b.read('ReadCooldownGroup','autoscaling','describeAutoScalingGroups',{'AutoScalingGroupNames':['${asg_name}']},'ReadCooldownInstances',{'coolGroup':E('$states.result.AutoScalingGroups[0]')})
  b.read('ReadCooldownInstances','ec2','describeInstances',{'Filters':[{'Name':'tag:aws:autoscaling:groupName','Values':['${asg_name}']}]},'CooldownReIpGate',{'coolInstances':E('$append([], $states.result.Reservations.Instances)')})
  b.choice('CooldownReIpGate',[("$coolGroup.AutoScalingGroupName='${asg_name}' and $count($coolGroup.Instances)<=2 and $count($coolGroup.Instances)=$count($coolInstances[InstanceId in $coolGroup.Instances.InstanceId and State.Name='running' and InstanceLifecycle='spot' and IamInstanceProfile.Arn='${spot_instance_profile_arn}' and $exists(PublicIpAddress) and PublicIpAddress!=$addresses[0].PublicIp])",'RecordCooldown')],'Failure')

 if b.name=='origin-guard':
  # A manually submitted event-shaped input is not trusted simply because the infrastructure Rule is filtered.
  accepted="($event.source='aws.ec2' and $event.\"detail-type\"='EC2 Instance State-change Notification' and $event.detail.\"instance-id\"='${od_instance_id}') or ($event.source='aws.ecs' and $event.\"detail-type\"='ECS Task State Change' and $event.detail.clusterArn='${ecs_cluster_arn}' and $event.detail.group='service:${ecs_service_name}' and $event.detail.lastStatus='STOPPED')"
  s['SignalChoice']['Choices'].append({'Condition':E("$request.trigger='event' and $not("+accepted+")"),'Next':'Done'})

 # Poll counts are an additional bound, never a substitute for elapsed-time deadlines.
 if b.name=='day-open':
  s['StartRds']['Assign']={'rdsWaitUntil':E('$millis()+1200000')}
  s['RdsAvailable']['Choices'][0]['Condition']=E("$dbStatus='available' and $millis()<=$rdsWaitUntil")
  s['RdsAvailable']['Choices'][1]['Condition']=E("$dbStatus in ['starting','stopped'] and $polls<40 and $millis()<$rdsWaitUntil")
 if b.name=='od-standby':
  s['StartOd']['Assign']={'odBootAt':E('$odBootAt=0 ? $millis() : $odBootAt'),'polls':0,'attempts':0}
  s['SsmOnlineChoice']['Choices'][1]['Condition']=E('$attempts<40 and $millis()<$odBootAt+1200000')
  s['OdReadinessChoice']['Choices'][0]['Condition']=E("$commandStatus='Success' and $commandCode=0 and $millis()<=$odBootAt+1200000")
  s['OdReadinessChoice']['Choices'][1]['Condition']=E("$commandStatus in ['Pending','InProgress','Delayed'] and $polls<36 and $millis()<$odBootAt+1200000")
 if b.name=='day-close':
  deadline="$toMillis($fromMillis($toMillis($states.context.Execution.StartTime),'[Y0001]-[M01]-[D01]','+0900') & 'T22:45:00+09:00')"
  s['NightRdsChoice']['Choices'][0]['Condition']=E("$dbStatus in ['stopping','stopped'] and ($mode.scope.S='rehearsal' or $millis()<="+deadline+")")
  s['NightRdsChoice']['Choices'][1]['Condition']=E("$polls<180 and ($mode.scope.S='rehearsal' or $millis()<"+deadline+")")
  for n in ['NightRdsChoice','FinalInvariant']:
   s[n]['Default']='Failure'
 if b.name!='ready-check':
  s['FailureModeChoice']['Choices'][0]['Condition']=E("$failedMode.state.S in ['failover-prep','failback','day-close']")
  tx=s['MarkDegraded']['Arguments']['TransactItems'];up=next(x['Update'] for x in tx if x.get('Update',{}).get('Key',{}).get('pk')==S('mode'))
  up['ConditionExpression']=up['ConditionExpression'].replace('#state IN (:s0, :s1)','#state IN (:s0, :s1, :s2)');up['ExpressionAttributeValues'][':s2']=S('day-close')
 if b.name=='origin-guard':
  # Each transient retry re-observes physical membership/health before taking a new address-write fence.
  s['WaitRetryAssociate']['Next']='StableSnapshot'
  st=s['StableTarget']['Choices'][0];st['Condition']=st['Condition'].replace('$freshTarget','$instances[InstanceId=$target][0]')

 if b.name!='ready-check':
  # Failures may be observed after a lease-free wait. Reacquire only an absent/expired lease; never adopt another execution's lock.
  s['FailureModeChoice']['Choices'][0]['Next']='ReadFailureLease'
  b.read('ReadFailureLease','dynamodb','getItem',{'TableName':TABLE,'Key':{'pk':S('lock#runtime')},'ConsistentRead':True},'FailureLeaseChoice',{'failureLease':E('$exists($states.result.Item) ? $states.result.Item : {}')})
  s['ReadFailureLease']['Catch']=[{'ErrorEquals':['States.ALL'],'Next':'Failed'}]
  b.choice('FailureLeaseChoice',[("$failureLease.owner.S=$states.context.Execution.Id and $failureLease.lockToken.S=$token",'MarkDegraded'),("$not($exists($failureLease.pk)) or $number($failureLease.expiresAt.N)<$millis()",'ReacquireFailure')],'Release')
  b.reacquire('ReacquireFailure','MarkDegraded',['failover-prep','failback','day-close'])

 if b.name=='origin-guard':
  # A lost response may not be noticed until the next 30-minute tick, after a 10-minute attestation expired.
  # Obtain a new host proof through the orchestrator rather than treating the observed holder as ready.
  need="$holder='${od_instance_id}' and $instances[InstanceId='${od_instance_id}'][0].State.Name='running' and $mode.state.S in ['failover-prep','failback'] and ($not($exists($tickReady.validUntil.N)) or $number($tickReady.validUntil.N)<=$millis() or $tickReady.sha.S!=$liveSha or $tickReady.taskDefinition.S!=$tdArn)"
  s['Reconcile']['Choices'].insert(0,{'Condition':E(need),'Next':'RecoverNeedsProof'})
  b.add('RecoverNeedsProof',{'Type':'Pass','Assign':{'dispatch':'recover-proof'},'Next':'BootstrapGate'})
  s['Dispatch']['Choices'].insert(0,{'Condition':E("$dispatch='recover-proof'"),'Next':'RequestRecoveryProof'})
  b.child('RequestRecoveryProof','${od_standby_arn}',{'action':'supervise','reason':'observed-holder-proof-expired'},'Release',['failover-prep','failback'])
 if b.name=='od-standby':
  # The orchestrator's fresh proof immediately requests a new guard run; waiting until another tick would expire it again.
  for c in s['Supervision']['Choices']:
   if c['Next']=='FallbackOdRefresh':c['Condition']=E("$mode.state.S in ['od-active','failover-prep','failback'] and $holder='${od_instance_id}' and $instances[InstanceId='${od_instance_id}'][0].State.Name='running'")
  s['SuperviseOdAttestation']['Next']='RecoveryProofChoice'
  b.choice('RecoveryProofChoice',[("$mode.state.S in ['failover-prep','failback']",'CommitRecoveredHolder')],'Release')
  b.child('CommitRecoveredHolder','${origin_guard_arn}',{'intent':'promote-od'},'Release',['failover-prep','failback'])

 # Reviewed response-loss recovery: Failure may already have recorded degraded before a later tick observes the real OD holder.
 # This exception proves an existing holder; it can never start OD or change its ENI, and remains bounded by the original day deadline.
 if b.name=='origin-guard':
  bounded="$holder='${od_instance_id}' and $instances[InstanceId='${od_instance_id}'][0].State.Name='running' and $exists($tickDay.odDeadline.N) and $number($tickDay.odDeadline.N)>$millis() and $db.DbInstanceStatus='available'"
  need=bounded+" and $mode.state.S in ['failover-prep','failback','degraded'] and ($not($exists($tickReady.validUntil.N)) or $number($tickReady.validUntil.N)<=$millis() or $tickReady.sha.S!=$liveSha or $tickReady.taskDefinition.S!=$tdArn or ($mode.state.S='degraded' and ($not($exists($tickReady.proofKind.S)) or $tickReady.proofKind.S!='recovery-endToEnd')))"
  next(c for c in s['Reconcile']['Choices'] if c['Next']=='RecoverNeedsProof')['Condition']=E(need)
  # Preserve stray-stop priority for unknown/expired deadline or unavailable RDS; never broadly exempt degraded.
  s['Reconcile']['Choices'].insert(1,{'Condition':E("$mode.state.S='degraded' and $holder='${od_instance_id}' and $instances[InstanceId='${od_instance_id}'][0].State.Name='running' and $not("+bounded+")"),'Next':'BootstrapStop'})
  op=next(x['ConditionCheck'] for x in s['FenceRequestRecoveryProof']['Arguments']['TransactItems'] if x.get('ConditionCheck',{}).get('Key',{}).get('pk')==S('mode'))
  op['ConditionExpression']=op['ConditionExpression'].replace('#state IN (:s0, :s1)','#state IN (:s0, :s1, :s2)');op['ExpressionAttributeValues'][':s2']=S('degraded')
  proof="($mode.state.S!='degraded' or $holder!='${od_instance_id}' or $target!='${od_instance_id}' or $ready.proofKind.S='recovery-endToEnd')"
  s['PromotionPolicy']['Choices'][0]['Condition']=E('('+s['PromotionPolicy']['Choices'][0]['Condition'][3:-3]+') and '+proof)
  stable=next(c for c in s['StablePromotionPolicy']['Choices'] if c['Next']=='StableTarget');stable['Condition']=E('('+stable['Condition'][3:-3]+') and '+proof)
 if b.name=='od-standby':
  bounded="$mode.state.S='degraded' and $request.reason='observed-holder-proof-expired' and $holder='${od_instance_id}' and $instances[InstanceId='${od_instance_id}'][0].State.Name='running' and $exists($day.odDeadline.N) and $number($day.odDeadline.N)>$millis() and $db.DbInstanceStatus='available'"
  stop=next(c for c in s['Supervision']['Choices'] if c['Next']=='BootstrapStop')
  stop['Condition']=E(stop['Condition'][3:-3].replace("$not($mode.state.S in ['failover-prep','od-active','failback'])", "($not($mode.state.S in ['failover-prep','od-active','failback']) and $not("+bounded+"))"))
  refresh=next(c for c in s['Supervision']['Choices'] if c['Next']=='FallbackOdRefresh')
  refresh['Condition']=E('('+refresh['Condition'][3:-3]+') or ('+bounded+')')
  # A caught/lost association response never reached the original parent's end-to-end smoke.
  recovery="$request.reason='observed-holder-proof-expired' and $mode.state.S in ['failover-prep','failback','degraded']"
  s['SuperviseOdReadiness']['Arguments']['Parameters']['checkMode']=[E(recovery+" ? 'endToEnd' : 'local'")]
  item=next(x['Put']['Item'] for x in s['SuperviseOdAttestation']['Arguments']['TransactItems'] if x.get('Put',{}).get('Item',{}).get('pk',{}).get('S','').startswith('{%'))
  item['proofKind']=S(E(recovery+" ? 'recovery-endToEnd' : 'local'"))
  s['RecoveryProofChoice']['Choices'][0]['Condition']=E("($mode.state.S in ['failover-prep','failback'] or ("+bounded+")) and $exists($day.odDeadline.N) and $number($day.odDeadline.N)>$millis()")
  op=next(x['ConditionCheck'] for x in s['FenceCommitRecoveredHolder']['Arguments']['TransactItems'] if x.get('ConditionCheck',{}).get('Key',{}).get('pk')==S('mode'))
  op['ConditionExpression']=op['ConditionExpression'].replace('#state IN (:s0, :s1)','#state IN (:s0, :s1, :s2)');op['ExpressionAttributeValues'][':s2']=S('degraded')

def day_open():
 b=Build('day-open');b.snapshot('Begin','NightGate')
 b.choice('NightGate',[("$instances[InstanceId='${od_instance_id}'][0].State.Name = 'stopped' and $odPublic = false and $count($group.Instances)=0 and $group.DesiredCapacity=0 and $holder in ['', '${od_instance_id}'] and $db.DbInstanceStatus in ['available','stopped']",'BootstrapGate')],'Failed')
 b.bootstrap('RdsChoice',['off','degraded'])
 b.choice('RdsChoice',[("$db.DbInstanceStatus='available'",'OpenMode'),("$db.DbInstanceStatus='stopped'",'StartRds')],'Failure')
 b.write('StartRds','rds','startDBInstance',{'DbInstanceIdentifier':'${db_instance_identifier}'},'WaitRds',['off','degraded'])
 b.wait('WaitRds',30,'PollRds');b.read('PollRds','rds','describeDBInstances',{'DbInstanceIdentifier':'${db_instance_identifier}'},'RdsAvailable',{'dbStatus':E('$states.result.DbInstances[0].DbInstanceStatus'),'polls':E('$polls+1')})
 b.choice('RdsAvailable',[("$dbStatus='available'",'OpenMode'),("$dbStatus in ['starting','stopped'] and $polls<40",'WaitRds')],'Failure')
 b.modewrite('OpenMode','spot-active','SetDesired',['off','degraded'])
 b.write('SetDesired','autoscaling','setDesiredCapacity',{'AutoScalingGroupName':'${asg_name}','DesiredCapacity':1,'HonorCooldown':False},'WaitSpot',['spot-active'])
 b.wait('WaitSpot',20,'ReadSpot');b.read('ReadSpot','autoscaling','describeAutoScalingGroups',{'AutoScalingGroupNames':['${asg_name}']},'SpotChoice',{'group':E('$states.result.AutoScalingGroups[0]'),'polls':E('$polls+1')})
 b.choice('SpotChoice',[("$count($group.Instances[LifecycleState='InService' and HealthStatus='Healthy'])=1",'PickSpot'),("$polls<90 and ($mode.scope.S='rehearsal' or $substring($fromMillis($millis(), '[H01]:[m01]', '+0900'),0,5) < '07:50')",'WaitSpot')],'OpenMissed')
 b.add('PickSpot',{'Type':'Pass','Assign':{'target':E("$group.Instances[LifecycleState='InService' and HealthStatus='Healthy'][0].InstanceId")},'Next':'ReadSpotInstance'})
 b.read('ReadSpotInstance','ec2','describeInstances',{'InstanceIds':[E('$target')]},'SpotIdentity',{'spot':E('$states.result.Reservations[0].Instances[0]')})
 b.choice('SpotIdentity',[("$spot.InstanceId=$target and $spot.State.Name='running' and $spot.InstanceLifecycle='spot' and $spot.IamInstanceProfile.Arn='${spot_instance_profile_arn}'",'SpotSmoke')],'Failure')
 b.local_smoke('SpotSmoke','$target','${spot_smoke_document_name}','AttestSpot');b.attest('AttestSpot','PromoteSpot')
 b.child('PromoteSpot','${origin_guard_arn}',{'intent':'promote-spot','target':E('$target')},'ReleasePromotion',['spot-active']);b.release('ReleasePromotion','WaitPromotion')
 b.wait('WaitPromotion',15,'PollPromotion');b.read('PollPromotion','ec2','describeAddresses',{'AllocationIds':['${eip_allocation_id}']},'Promoted',{'newHolder':E('$states.result.Addresses[0].InstanceId'),'attempts':E('$attempts+1')})
 b.choice('Promoted',[("$newHolder=$target",'ReacquireSmoke'),("$attempts<8",'WaitPromotion')],'Failed');b.reacquire('ReacquireSmoke','SpotEndToEnd',['spot-active'])
 b.local_smoke('SpotEndToEnd','$target','${spot_smoke_document_name}','Release',mode='endToEnd')
 b.child('OpenMissed','${od_standby_arn}',{'action':'prepare','reason':'open-missed'},'Failure',['spot-active'])
 return b.finish()

def ready_check():
 b=Build('ready-check');b.snapshot('Begin','ReadReady')
 b.read('ReadReady','dynamodb','getItem',{'TableName':TABLE,'Key':{'pk':S(E("'ready#' & $holder"))},'ConsistentRead':True},'ReadLease',{'ready':E('$exists($states.result.Item) ? $states.result.Item : {}')})
 b.read('ReadLease','dynamodb','getItem',{'TableName':TABLE,'Key':{'pk':S('lock#runtime')},'ConsistentRead':True},'ReadyChoice',{'lock':E('$exists($states.result.Item) ? $states.result.Item : {}')})
 b.choice('ReadyChoice',[("$mode.state.S in ['spot-active','od-active'] and $db.DbInstanceStatus='available' and $service.RunningCount=1 and $ready.instanceId.S=$holder and $ready.sha.S=$liveSha and $ready.taskDefinition.S=$tdArn and $number($ready.validUntil.N)>$millis() and ($not($exists($lock.pk)) or $number($lock.expiresAt.N)<$millis()) and (($mode.state.S='spot-active' and $holder in $group.Instances[LifecycleState='InService' and HealthStatus='Healthy'].InstanceId and $instances[InstanceId=$holder][0].State.Name='running' and $instances[InstanceId=$holder][0].InstanceLifecycle='spot' and $instances[InstanceId=$holder][0].IamInstanceProfile.Arn='${spot_instance_profile_arn}' and $instances[InstanceId='${od_instance_id}'][0].State.Name='stopped' and $odPublic=false) or ($mode.state.S='od-active' and $holder='${od_instance_id}' and $instances[InstanceId='${od_instance_id}'][0].State.Name='running'))",'Done')],'Failed')
 # This machine is strictly read-only, including error paths.
 for n in ['Failure','Release','EndChoice']:b.s.pop(n)
 return b.finish()

def origin_guard():
 b=Build('origin-guard');b.snapshot('Begin','IntentChoice')
 b.choice('IntentChoice',[("$not($exists($request.intent)) or $request.intent='reconcile'",'Reconcile'),("$request.intent in ['promote-spot','promote-od','promote-od-early','failback','restore-od','park-od']",'SelectTarget')],'Failed')
 b.choice('Reconcile',[("$holder='${od_instance_id}' and $mode.state.S='od-active'",'BootstrapSupervise'),("$instances[InstanceId='${od_instance_id}'][0].State.Name='running' and $not($mode.state.S in ['failover-prep','od-active','failback'])",'BootstrapStop'),("$holder in $group.Instances[LifecycleState='InService' and HealthStatus='Healthy'].InstanceId and $not($event.\"detail-type\"='EC2 Spot Instance Interruption Warning' and $event.detail.\"instance-id\"=$holder)",'Done'),("$mode.state.S in ['spot-active','degraded'] and ($holder='' or $event.\"detail-type\"='EC2 Spot Instance Interruption Warning' and $event.detail.\"instance-id\"=$holder)",'BootstrapPrepare')],'Done')
 # All child requests also require a lease. Dispatch after a common atomic bootstrap.
 for n,action in [('BootstrapSupervise','supervise'),('BootstrapStop','stop'),('BootstrapPrepare','prepare')]:b.add(n,{'Type':'Pass','Assign':{'dispatch':action},'Next':'BootstrapGate'})
 b.add('SelectTarget',{'Type':'Pass','Assign':{'dispatch':'associate','target':E("$request.intent in ['promote-od','promote-od-early','restore-od','park-od'] ? '${od_instance_id}' : $request.target")},'Next':'TargetPrecheck'})
 b.choice('TargetPrecheck',[("$target='${od_instance_id}' or ($type($target)='string' and $target in $group.Instances[LifecycleState='InService' and HealthStatus='Healthy'].InstanceId and $instances[InstanceId=$target][0].InstanceLifecycle='spot' and $instances[InstanceId=$target][0].IamInstanceProfile.Arn='${spot_instance_profile_arn}' and $instances[InstanceId=$target][0].State.Name='running')",'ReadTargetReady')],'Failed')
 b.read('ReadTargetReady','dynamodb','getItem',{'TableName':TABLE,'Key':{'pk':S(E("'ready#' & $target"))},'ConsistentRead':True},'ReadInstanceRecord',{'ready':E('$exists($states.result.Item) ? $states.result.Item : {}')})
 b.read('ReadInstanceRecord','dynamodb','getItem',{'TableName':TABLE,'Key':{'pk':S(E("'instance#' & $target"))},'ConsistentRead':True},'ReadPromotion',{'instanceRecord':E('$exists($states.result.Item) ? $states.result.Item : {}')})
 b.read('ReadPromotion','dynamodb','getItem',{'TableName':TABLE,'Key':{'pk':S('promotion')},'ConsistentRead':True},'PromotionPolicy',{'promotion':E('$exists($states.result.Item) ? $states.result.Item : {}')})
 ready="$ready.instanceId.S=$target and $ready.sha.S=$liveSha and $ready.taskDefinition.S=$tdArn and $number($ready.validUntil.N)>$millis()"
 spot="($target!='${od_instance_id}' and $not($exists($instanceRecord.interruptionAt)) and $not($exists($instanceRecord.terminatingAt)) and ($not($exists($instanceRecord.rebalanceAt.N)) or $number($instanceRecord.rebalanceAt.N)<$millis()-1800000) and $millis()-$toMillis($instances[InstanceId=$target][0].LaunchTime)>=60000)"
 early="($request.intent='promote-od-early' and $mode.state.S='failover-prep' and ($holder='' or $instances[InstanceId=$holder][0].State.Name in ['terminated','shutting-down','stopped']) and $target='${od_instance_id}')"
 park="($request.intent='park-od' and $mode.state.S='day-close' and $count($group.Instances)=0 and $group.DesiredCapacity=0 and $instances[InstanceId='${od_instance_id}'][0].State.Name='stopped' and $odPublic=false)"
 limits="($not($exists($promotion.dayMoves.N)) or $promotion.day.S!=$fromMillis($millis(),'[Y0001]-[M01]-[D01]','+0900') or $number($promotion.dayMoves.N)<6) and $count($promotion.times.L[$number(N)>$millis()-1800000])<2"
 b.choice('PromotionPolicy',[(f"({park}) or (({limits}) and (({early}) or (({ready}) and (({spot}) or ($target='${{od_instance_id}}' and $instances[InstanceId=$target][0].State.Name='running' and $mode.state.S in ['failover-prep','failback','degraded','od-active','spot-active'])))))",'BootstrapGate')],'Failed')
 b.bootstrap('Dispatch')
 b.choice('Dispatch',[("$dispatch='supervise'",'Supervise'),("$dispatch='stop'",'StopStray'),("$dispatch='prepare'",'Prepare'),("$target=$holder",'Release')],'WaitStable')
 for n,a in [('Supervise','supervise'),('StopStray','stop'),('Prepare','prepare')]:b.child(n,'${od_standby_arn}',{'action':a,'reason':'guard-signal'},'Release')
 b.wait('WaitStable',15,'ReReadTarget')
 b.read('ReReadTarget','ec2','describeInstances',{'InstanceIds':[E('$target')]},'StableTarget',{'freshTarget':E('$states.result.Reservations[0].Instances[0]')})
 b.choice('StableTarget',[("$freshTarget.InstanceId=$target and (($request.intent in ['park-od','promote-od-early'] and $target='${od_instance_id}' and $freshTarget.State.Name='stopped') or ($freshTarget.State.Name='running' and ($target='${od_instance_id}' or ($freshTarget.InstanceLifecycle='spot' and $freshTarget.IamInstanceProfile.Arn='${spot_instance_profile_arn}'))))",'Associate')],'Failure')
 b.write('Associate','ec2','associateAddress',{'AllocationId':'${eip_allocation_id}','InstanceId':E('$target'),'AllowReassociation':True},'WaitAddress',assign={'attempts':0},catch='AssociateFailure')
 b.s['Associate']['Catch']=[{'ErrorEquals':['Ec2.InvalidNetworkInterfaceID.NotFoundException','Ec2.RequestLimitExceededException','Ec2.ThrottlingException'],'Next':'AssociateFailure'},{'ErrorEquals':['States.ALL'],'Next':'Failure'}]
 b.add('AssociateFailure',{'Type':'Pass','Assign':{'attempts':E('$attempts+1')},'Next':'RetryAssociate'})
 b.choice('RetryAssociate',[("$attempts<8",'WaitRetryAssociate')],'Failure');b.wait('WaitRetryAssociate',15,'FenceAssociate')
 m=b.s['FenceAssociate']['Arguments']['TransactItems'][1]['ConditionCheck']
 m['ConditionExpression'] += ' AND ((#state = :close AND :intent = :park) OR (#state = :prep AND :intent = :early) OR (#state = :failback AND :intent = :failbackIntent) OR (#state IN (:active, :prep, :failback, :degraded, :od) AND :intent IN (:spotIntent, :odIntent, :restoreIntent)))'
 m['ExpressionAttributeValues'].update({':close':S('day-close'),':intent':S(E('$request.intent')),':park':S('park-od'),':early':S('promote-od-early'),':failbackIntent':S('failback'),':spotIntent':S('promote-spot'),':odIntent':S('promote-od'),':restoreIntent':S('restore-od'),':active':S('spot-active'),':prep':S('failover-prep'),':failback':S('failback'),':degraded':S('degraded'),':od':S('od-active')})
 # The attestation is checked in the same transaction as the lease, except explicit stopped-OD parking/A1 recovery.
 b.s['FenceAssociate']['Arguments']['TransactItems'].append({'ConditionCheck':{'TableName':TABLE,'Key':{'pk':S(E("'ready#' & $target"))},'ConditionExpression':'(#id = :target AND sha = :sha AND taskDefinition = :td AND validUntil > :now) OR :intent IN (:park, :early)','ExpressionAttributeNames':{'#id':'instanceId'},'ExpressionAttributeValues':{':target':S(E('$target')),':sha':S(E('$liveSha')),':td':S(E('$tdArn')),':now':N('$millis()'),':intent':S(E('$request.intent')),':park':S('park-od'),':early':S('promote-od-early')}}})
 b.wait('WaitAddress',10,'VerifyAddress');b.read('VerifyAddress','ec2','describeAddresses',{'AllocationIds':['${eip_allocation_id}']},'AddressVerified',{'actualHolder':E('$states.result.Addresses[0].InstanceId'),'polls':E('$polls+1')})
 b.choice('AddressVerified',[("$actualHolder=$target",'RecordPromotion'),("$polls<6",'WaitAddress')],'Failure')
 item={'pk':S('promotion'),'holder':S(E('$target')),'target':S(E('$target')),'at':N('$millis()'),'day':S(E("$fromMillis($millis(),'[Y0001]-[M01]-[D01]','+0900')")),'dayMoves':N("($promotion.day.S=$fromMillis($millis(),'[Y0001]-[M01]-[D01]','+0900') and $exists($promotion.dayMoves.N) ? $number($promotion.dayMoves.N) : 0)+1"),'times':{'L':E("$append($exists($promotion.times.L) ? $promotion.times.L[$number(N)>$millis()-1800000] : [], [{'N':$string($millis())}])")},'ttl':N('$floor($millis()/1000)+172800')}
 b.add('RecordPromotion',{'Type':'Pass','Next':'ModeAfterPromotion'})
 b.choice('ModeAfterPromotion',[("$request.intent in ['park-od','promote-od-early']",'RecordParking'),("$target='${od_instance_id}'",'OdActive')],'SpotActive')
 b.control('RecordParking',{'Put':{'TableName':TABLE,'Item':item}},'Release')
 b.modewrite('OdActive','od-active','Release',['failover-prep','failback','degraded','od-active','spot-active']);b.modewrite('SpotActive','spot-active','Release',['spot-active','failback','failover-prep','degraded'])
 for n in ['OdActive','SpotActive']:b.s[n]['Arguments']['TransactItems'].append({'Put':{'TableName':TABLE,'Item':item}})
 return b.finish()

def od_standby():
 b=Build('od-standby');b.snapshot('Begin','ReadDay')
 b.read('ReadDay','dynamodb','getItem',{'TableName':TABLE,'Key':{'pk':S(E('$dayKey'))},'ConsistentRead':True},'ReadHold',{'day':E('$exists($states.result.Item) ? $states.result.Item : {}')})
 b.read('ReadHold','dynamodb','getItem',{'TableName':TABLE,'Key':{'pk':S('standby-hold')},'ConsistentRead':True},'ActionChoice',{'hold':E('$exists($states.result.Item.pk)')})
 b.choice('ActionChoice',[("$request.action='stop'",'BootstrapStop'),("$request.action='supervise'",'Supervision'),("$not($exists($request.action)) or $request.action='prepare'",'PrepareGate')],'Failed')
 b.add('BootstrapStop',{'Type':'Pass','Assign':{'path':'stop'},'Next':'BootstrapGate'})
 b.choice('Supervision',[("$instances[InstanceId='${od_instance_id}'][0].State.Name='running' and ($not($mode.state.S in ['failover-prep','od-active','failback']) or $not($exists($day.odDeadline.N)) or $number($day.odDeadline.N)<=$millis())",'BootstrapStop'),("$mode.state.S='od-active' and $holder='${od_instance_id}' and $exists($day.odStartedAt.N) and $millis()-$number($day.odStartedAt.N)>=3600000 and ($not($exists($day.failbacks.N)) or $number($day.failbacks.N)<2) and $fromMillis($millis(),'[H01]:[m01]','+0900')<'21:00' and $count($group.Instances[LifecycleState='InService' and HealthStatus='Healthy'])=1 and $hold=false",'SelectFailback')],'Done')
 b.add('SelectFailback',{'Type':'Pass','Assign':{'target':E("$group.Instances[LifecycleState='InService' and HealthStatus='Healthy'][0].InstanceId"),'path':'failback'},'Next':'FailbackIdentityRead'})
 b.read('FailbackIdentityRead','ec2','describeInstances',{'InstanceIds':[E('$target')]},'FailbackIdentity',{'candidate':E('$states.result.Reservations[0].Instances[0]')})
 b.choice('FailbackIdentity',[("$candidate.InstanceId=$target and $candidate.State.Name='running' and $candidate.InstanceLifecycle='spot' and $candidate.IamInstanceProfile.Arn='${spot_instance_profile_arn}' and $millis()-$toMillis($candidate.LaunchTime)>=900000",'BootstrapGate')],'Failed')
 b.choice('PrepareGate',[("$hold=false and $db.DbInstanceStatus='available' and $mode.state.S in ['spot-active','degraded'] and $instances[InstanceId='${od_instance_id}'][0].State.Name='stopped' and ($not($exists($day.starts.N)) or $number($day.starts.N)<3) and ($mode.scope.S='rehearsal' or ($number($fromMillis($millis(),'[F1]','+0900'))<=5 and $fromMillis($millis(),'[H01]:[m01]','+0900')>='07:00' and $fromMillis($millis(),'[H01]:[m01]','+0900')<'21:40'))",'PreparePath')],'Failed')
 b.add('PreparePath',{'Type':'Pass','Assign':{'path':'prepare','target':'${od_instance_id}'},'Next':'BootstrapGate'})
 b.bootstrap('PathChoice')
 b.choice('PathChoice',[("$path='stop'",'StopOd'),("$path='failback'",'FailbackSmoke')],'FailoverMode')
 b.modewrite('FailoverMode','failover-prep','RecordStart',['spot-active','degraded'])
 b.control('RecordStart',{'Update':{'TableName':TABLE,'Key':{'pk':S(E('$dayKey'))},'UpdateExpression':'SET odStartedAt=:started, odDeadline=:deadline, ttl=:ttl ADD starts :one','ConditionExpression':'attribute_not_exists(starts) OR starts < :max','ExpressionAttributeValues':{':started':N('$millis()'),':deadline':N("$min([$millis()+54000000,$toMillis($fromMillis($millis(),'[Y0001]-[M01]-[D01]','+0900') & 'T22:00:00+09:00')])"),':ttl':N('$floor($millis()/1000)+172800'),':one':{'N':'1'},':max':{'N':'3'}}}},'SetDesiredSha',['failover-prep'],True)
 b.write('SetDesiredSha','ssm','putParameter',{'Name':'${desired_image_parameter}','Value':E('$liveSha'),'Type':'String','Overwrite':True},'EnableOdPublic',['failover-prep'],True)
 b.write('EnableOdPublic','ec2','modifyNetworkInterfaceAttribute',{'NetworkInterfaceId':'${od_eni_id}','AssociatePublicIpAddress':True},'StartOd',['failover-prep'],True,catch='A1Check')
 b.choice('A1Check',[("$holder='' or $instances[InstanceId=$holder][0].State.Name in ['terminated','shutting-down','stopped']",'EarlyParking')],'Failure')
 b.child('EarlyParking','${origin_guard_arn}',{'intent':'promote-od-early'},'ReleaseEarly',['failover-prep'])
 b.release('ReleaseEarly','WaitEarly');b.wait('WaitEarly',15,'ReadEarly');b.read('ReadEarly','ec2','describeAddresses',{'AllocationIds':['${eip_allocation_id}']},'EarlyMoved',{'holder':E("$exists($states.result.Addresses[0].InstanceId) ? $states.result.Addresses[0].InstanceId : ''"),'attempts':E('$attempts+1')})
 b.choice('EarlyMoved',[("$holder='${od_instance_id}'",'ReacquireEarly'),("$attempts<8",'WaitEarly')],'Failed');b.reacquire('ReacquireEarly','StartOd',['failover-prep'])
 b.write('StartOd','ec2','startInstances',{'InstanceIds':['${od_instance_id}']},'ReleaseBoot',['failover-prep'],True)
 b.release('ReleaseBoot','WaitBoot');b.wait('WaitBoot',15,'PollBoot')
 b.read('PollBoot','ec2','describeInstances',{'InstanceIds':['${od_instance_id}']},'BootChoice',{'od':E('$states.result.Reservations[0].Instances[0]'),'polls':E('$polls+1')})
 b.choice('BootChoice',[("$od.InstanceId='${od_instance_id}' and $od.State.Name='running' and ($exists($od.PublicIpAddress) or $holder='${od_instance_id}')",'ReadSsmOnline'),("$polls<20",'WaitBoot')],'Failed')
 b.read('ReadSsmOnline','ssm','describeInstanceInformation',{'Filters':[{'Key':'InstanceIds','Values':['${od_instance_id}']}]},'SsmOnlineChoice',{'ssmOnline':E("$count($states.result.InstanceInformationList[InstanceId='${od_instance_id}' and PingStatus='Online'])=1"),'attempts':E('$attempts+1')})
 b.choice('SsmOnlineChoice',[("$ssmOnline",'ReacquireReadiness'),("$attempts<40",'WaitSsm')],'Failed');b.wait('WaitSsm',15,'ReadSsmOnline');b.reacquire('ReacquireReadiness','OdReadiness',['failover-prep'])
 b.local_smoke('OdReadiness',"'${od_instance_id}'",'${od_readiness_document_name}','AttestOd');b.attest('AttestOd','PromoteOd')
 b.child('PromoteOd','${origin_guard_arn}',{'intent':'promote-od'},'ReleasePromoteOd',['failover-prep']);b.release('ReleasePromoteOd','WaitOdPromotion')
 b.wait('WaitOdPromotion',15,'ReadOdPromotion');b.read('ReadOdPromotion','ec2','describeAddresses',{'AllocationIds':['${eip_allocation_id}']},'OdPromoted',{'newHolder':E('$states.result.Addresses[0].InstanceId'),'polls':E('$polls+1')})
 b.choice('OdPromoted',[("$newHolder='${od_instance_id}'",'ReacquireE2e'),("$polls<28",'WaitOdPromotion')],'Failed');b.reacquire('ReacquireE2e','OdEndToEnd',['od-active'])
 b.local_smoke('OdEndToEnd',"'${od_instance_id}'",'${od_readiness_document_name}','Release',mode='endToEnd')
 b.local_smoke('RefreshOdReadiness',"'${od_instance_id}'",'${od_readiness_document_name}','RefreshOdTarget');b.add('RefreshOdTarget',{'Type':'Pass','Assign':{'failbackTarget':E('$target'),'target':'${od_instance_id}'},'Next':'RefreshOdAttestation'});b.attest('RefreshOdAttestation','RestoreFailbackTarget');b.add('RestoreFailbackTarget',{'Type':'Pass','Assign':{'target':E('$failbackTarget')},'Next':'FailbackSmoke'});b.s['PathChoice']['Choices'][1]['Next']='RefreshOdReadiness'
 b.local_smoke('FailbackSmoke','$target','${spot_smoke_document_name}','AttestFailback');b.attest('AttestFailback','FailbackMode')
 b.modewrite('FailbackMode','failback','RecordFailback',['od-active'])
 b.control('RecordFailback',{'Update':{'TableName':TABLE,'Key':{'pk':S(E('$dayKey'))},'UpdateExpression':'ADD failbacks :one','ConditionExpression':'attribute_not_exists(failbacks) OR failbacks < :max','ExpressionAttributeValues':{':one':{'N':'1'},':max':{'N':'2'}}}},'DisableOdPublic',['failback'])
 b.write('DisableOdPublic','ec2','modifyNetworkInterfaceAttribute',{'NetworkInterfaceId':'${od_eni_id}','AssociatePublicIpAddress':False},'RequestFailback',['failback'],True)
 b.child('RequestFailback','${origin_guard_arn}',{'intent':'failback','target':E('$target')},'ReleaseFailback',['failback']);b.release('ReleaseFailback','WaitFailback')
 b.wait('WaitFailback',15,'ReadFailbackAddress');b.read('ReadFailbackAddress','ec2','describeAddresses',{'AllocationIds':['${eip_allocation_id}']},'FailbackMoved',{'newHolder':E('$states.result.Addresses[0].InstanceId'),'polls':E('$polls+1')})
 b.choice('FailbackMoved',[("$newHolder=$target",'ReacquireFailback'),("$polls<8",'WaitFailback')],'Failed');b.reacquire('ReacquireFailback','FailbackE2e',['spot-active'])
 b.local_smoke('FailbackE2e','$target','${spot_smoke_document_name}','StopOd',mode='endToEnd');b.s['FailbackE2eChoice']['Default']='RestoreRequest'
 b.child('RestoreRequest','${origin_guard_arn}',{'intent':'restore-od'},'Failure',['spot-active','failback'])
 b.write('StopOd','ec2','stopInstances',{'InstanceIds':['${od_instance_id}'],'Force':False},'WaitStopped')
 b.wait('WaitStopped',15,'ReadStopped');b.read('ReadStopped','ec2','describeInstances',{'InstanceIds':['${od_instance_id}']},'StoppedChoice',{'odState':E('$states.result.Reservations[0].Instances[0].State.Name'),'polls':E('$polls+1')})
 b.choice('StoppedChoice',[("$odState='stopped'",'EnsurePublicOff'),("$polls<40",'WaitStopped')],'Failure')
 b.write('EnsurePublicOff','ec2','modifyNetworkInterfaceAttribute',{'NetworkInterfaceId':'${od_eni_id}','AssociatePublicIpAddress':False},'Release',hold=True)
 return b.finish()

def day_close():
 b=Build('day-close');b.snapshot('Begin','CloseInput')
 b.choice('CloseInput',[("($request.rdsStop='schedule' or ($mode.scope.S='rehearsal' and $request.rdsStop='self')) and $request.parkEip='od'",'CloseMode')],'Failed')
 # Close mode deliberately precedes lease acquisition, fencing out promotions already waiting for the lease.
 check=b.modecheck(MODE_STATES)['ConditionCheck'];up={k:v for k,v in check.items() if k!='ConditionExpression'};up['ConditionExpression']=check['ConditionExpression'];up['UpdateExpression']='SET #state = :close';up['ExpressionAttributeValues'][':close']=S('day-close')
 b.txn('CloseMode',[{'ConditionCheck':{'TableName':TABLE,'Key':{'pk':S('maintenance')},'ConditionExpression':'attribute_not_exists(pk)'}},{'Update':up}],'BootstrapGate','Failed')
 b.bootstrap('ScaleZero',['day-close'])
 b.write('ScaleZero','autoscaling','setDesiredCapacity',{'AutoScalingGroupName':'${asg_name}','DesiredCapacity':0,'HonorCooldown':False},'StopOd',['day-close'])
 b.write('StopOd','ec2','stopInstances',{'InstanceIds':['${od_instance_id}'],'Force':False},'WaitDrain',['day-close'])
 b.wait('WaitDrain',30,'ReadDrain');b.read('ReadDrain','autoscaling','describeAutoScalingGroups',{'AutoScalingGroupNames':['${asg_name}']},'ReadOdStopped',{'group':E('$states.result.AutoScalingGroups[0]'),'polls':E('$polls+1')})
 b.read('ReadOdStopped','ec2','describeInstances',{'InstanceIds':['${od_instance_id}']},'DrainChoice',{'od':E('$states.result.Reservations[0].Instances[0]')})
 b.choice('DrainChoice',[("$count($group.Instances)=0 and $group.DesiredCapacity=0 and $od.State.Name='stopped'",'PublicOff'),("$polls<150",'WaitDrain')],'Failure')
 b.write('PublicOff','ec2','modifyNetworkInterfaceAttribute',{'NetworkInterfaceId':'${od_eni_id}','AssociatePublicIpAddress':False},'ParkEip',['day-close'],True)
 b.child('ParkEip','${origin_guard_arn}',{'intent':'park-od'},'ReleasePark',['day-close']);b.release('ReleasePark','WaitPark')
 b.wait('WaitPark',15,'ReadPark');b.read('ReadPark','ec2','describeAddresses',{'AllocationIds':['${eip_allocation_id}']},'ParkChoice',{'actualHolder':E('$states.result.Addresses[0].InstanceId'),'attempts':E('$attempts+1')})
 b.choice('ParkChoice',[("$actualHolder='${od_instance_id}'",'ReacquireClose'),("$attempts<8",'WaitPark')],'Failed');b.reacquire('ReacquireClose','RdsStopChoice',['day-close'])
 b.choice('RdsStopChoice',[("$request.rdsStop='self'",'ReadRdsBeforeStop')],'ReleaseNightWait')
 b.read('ReadRdsBeforeStop','rds','describeDBInstances',{'DbInstanceIdentifier':'${db_instance_identifier}'},'RdsNeedsStop',{'dbStatus':E('$states.result.DbInstances[0].DbInstanceStatus')})
 b.choice('RdsNeedsStop',[("$dbStatus='available'",'StopRds'),("$dbStatus in ['stopping','stopped']",'ReleaseNightWait')],'Failure')
 b.write('StopRds','rds','stopDBInstance',{'DbInstanceIdentifier':'${db_instance_identifier}'},'ReleaseNightWait',['day-close'])
 b.release('ReleaseNightWait','NightWait')
 b.add('NightWait',{'Type':'Wait','Seconds':30,'Next':'ReadNightRds'})
 b.read('ReadNightRds','rds','describeDBInstances',{'DbInstanceIdentifier':'${db_instance_identifier}'},'NightRdsChoice',{'dbStatus':E('$states.result.DbInstances[0].DbInstanceStatus'),'polls':E('$polls+1')})
 b.choice('NightRdsChoice',[("$dbStatus in ['stopping','stopped']",'ReacquireFinal'),("$polls<180 and ($mode.scope.S='rehearsal' or $fromMillis($millis(),'[H01]:[m01]','+0900')<'22:45')",'NightWait')],'Failed')
 b.reacquire('ReacquireFinal','FinalRead',['day-close']);b.snapshot('FinalRead','FinalInvariant','Final')
 b.choice('FinalInvariant',[("$count($group.Instances)=0 and $group.DesiredCapacity=0 and $holder='${od_instance_id}' and $instances[InstanceId='${od_instance_id}'][0].State.Name='stopped' and $odPublic=false and $db.DbInstanceStatus in ['stopping','stopped']",'OffMode')],'Failure')
 b.modewrite('OffMode','off','Release',['day-close'])
 return b.finish()

if __name__=='__main__':
 for name,fn in [('day-open',day_open),('ready-check',ready_check),('day-close',day_close),('origin-guard',origin_guard),('od-standby',od_standby)]:
  d=fn();text=json.dumps(d,indent=2,ensure_ascii=False).replace('"__timeout_seconds__"','${timeout_seconds}')+'\n';(D/(name+'.asl.json')).write_text(text)
  print(name,len(d['States']),'states')
