#!/usr/bin/env node
// Offline mutations execute real generated JSONata and the strict fixture's atomic DynamoDB condition interpreter.
import assert from 'node:assert/strict';
import {readDoc,fixture,transform,evaluate,contract,vars,replay,caughtResponseLossFixture} from './runtime-asl.test.mjs';
const fixed=Date.parse('2026-10-21T09:00:00.000Z'),SPOT='i-00000000000000002';
const owner='arn:aws:states:ap-northeast-1:111111111111:execution:MOCK:test',token='MOCK-token',until=fixed+8880000;
const names=['day-open','ready-check','day-close','origin-guard','od-standby'];
let killed=0,controls=0;const byType={};
function scrub(tx){for(const item of tx){const v=Object.values(item)[0],expr=(v.ConditionExpression??'')+' '+(v.UpdateExpression??'');for(const k of Object.keys(v.ExpressionAttributeNames??{}))if(!new RegExp(k+'(?![A-Za-z0-9_])').test(expr))delete v.ExpressionAttributeNames[k];for(const k of Object.keys(v.ExpressionAttributeValues??{}))if(!new RegExp(k+'(?![A-Za-z0-9_])').test(expr))delete v.ExpressionAttributeValues[k];}}
async function prepared(st){
 const m=fixture();const md=m.store.get('mode');const modeOp=st.Arguments.TransactItems.map(x=>x.ConditionCheck??x.Update).find(x=>x?.Key?.pk?.S==='mode');md.state.S=modeOp.ExpressionAttributeValues[':spotIntent']?'spot-active':modeOp.ExpressionAttributeValues[':s0'].S;
 const mode=structuredClone(md),ctx={Execution:{Id:owner,StartTime:new Date(fixed).toISOString()},State:{EnteredTime:new Date(fixed).toISOString()}};
 const b={mode,request:{trigger:'manual',scheduledTime:'manual-MUTATION',intent:'promote-spot'},token,writeUntil:until,startedAt:fixed,target:SPOT,holder:vars.od_instance_id,liveSha:vars.expected_image_sha,tdArn:'arn:aws:ecs:ap-northeast-1:111111111111:task-definition/ec-portfolio-demo-api:42',promotion:{},launchDay:{},day:{},dayKey:'day#2026-10-21',group:{Instances:[{InstanceId:SPOT,LifecycleState:'InService',HealthStatus:'Healthy'}]},event:{},signalTarget:SPOT,signalField:'interruptionAt',states:{context:ctx}};
 m.store.set('lock#runtime',{pk:{S:'lock#runtime'},owner:{S:owner},lockToken:{S:token},expiresAt:{N:String(fixed+9600000)},writeUntil:{N:String(until)},redriveCount:{N:'0'}});
 m.store.set('ready#'+SPOT,{pk:{S:'ready#'+SPOT},instanceId:{S:SPOT},sha:{S:vars.expected_image_sha},taskDefinition:{S:b.tdArn},validUntil:{N:String(fixed+600000)}});
 return {m,b,args:await transform(st.Arguments,b,fixed)};
}
async function rejected(m,args,label){const before=m.writes.length;await assert.rejects(()=>m.call('arn:aws:states:::aws-sdk:dynamodb:transactWriteItems',args,label),e=>e.awsError==='DynamoDb.TransactionCanceledException');assert.equal(m.writes.length,before);}
async function mutation(st,type,edit,corrupt){
 const c=await prepared(st);await c.m.call(st.Resource,c.args,'unmutated-control');assert.ok(c.m.writes.length>0);controls++;
 const bad=await prepared(st);await corrupt(bad);await rejected(bad.m,bad.args,'unmutated-denial');controls++;
 const mut=structuredClone(bad.args);edit(mut.TransactItems);scrub(mut.TransactItems);
 const before=bad.m.writes.length;await bad.m.call(st.Resource,mut,'mutated');assert.ok(bad.m.writes.length>before,'Mutant must violate denied-write invariant');killed++;byType[type]=(byType[type]??0)+1;
}
const lockOp=tx=>tx.map(x=>x.Update??x.Delete).find(x=>x?.Key?.pk?.S==='lock#runtime');
const modeOp=tx=>tx.map(x=>x.ConditionCheck??x.Update).find(x=>x?.Key?.pk?.S==='mode');
function removePart(op,part){assert.ok(op.ConditionExpression.includes(part),part);op.ConditionExpression=op.ConditionExpression.replace(part+' AND ','').replace(' AND '+part,'');assert.ok(!op.ConditionExpression.includes(part));}
for(const name of names){const doc=readDoc(name);contract(doc,name);
 for(const[n,st]of Object.entries(doc.States)){
  if(st.Type!=='Task'||!st.Resource.endsWith(':transactWriteItems'))continue;
  if(!st.Arguments.TransactItems.some(x=>x.Update?.Key.pk.S==='lock#runtime'||x.Delete?.Key.pk.S==='lock#runtime'))continue;
  await mutation(st,'owner',tx=>removePart(lockOp(tx),'#owner = :owner'),async({m})=>{m.store.get('lock#runtime').owner.S='FOREIGN'});
  await mutation(st,'token',tx=>removePart(lockOp(tx),'lockToken = :token'),async({m})=>{m.store.get('lock#runtime').lockToken.S='FOREIGN'});
  await mutation(st,'lease-expiry',tx=>removePart(lockOp(tx),'expiresAt > :minExpiry'),async({m})=>{m.store.get('lock#runtime').expiresAt.N=String(fixed-1)});
  await mutation(st,'enabled',tx=>removePart(modeOp(tx),'enabled = :yes'),async({m})=>{m.store.get('mode').enabled.BOOL=false});
  await mutation(st,'approval-binding',tx=>removePart(modeOp(tx),'approvalRef = :approval'),async({m})=>{m.store.get('mode').approvalRef.S='DIFFERENT-APPROVAL'});
  await mutation(st,'maintenance',tx=>tx.splice(tx.findIndex(x=>x.ConditionCheck?.Key.pk.S==='maintenance'),1),async({m})=>{m.store.set('maintenance',{pk:{S:'maintenance'}})});
  await mutation(st,'current-redrive',tx=>{removePart(lockOp(tx),':currentRedrive = :zero');removePart(modeOp(tx),':currentRedrive = :zero')},async({b,args})=>{b.states.context.Execution.RedriveCount=1;const next=await transform(st.Arguments,b,fixed);Object.assign(args,next)});
  await mutation(st,'stored-redrive',tx=>removePart(lockOp(tx),'redriveCount = :zero'),async({m})=>{m.store.get('lock#runtime').redriveCount.N='1'});
 }
 // Full graph mutation must be rejected rather than silently compiled away.
 const bad=structuredClone(doc);bad.States.ReadMaintenance.Next='Init';assert.throws(()=>contract(bad,name),e=>e.code==='ERR_ASSERTION');killed++;byType['ArmGate-dominance']=(byType['ArmGate-dominance']??0)+1;
 // Each initial arming condition mutant is evaluated against a real bad context.
 const arm=doc.States.ArmGate.Choices[0].Condition;
 const cases=[['enabled',"$mode.enabled.BOOL = true",()=>{const md=fixture().store.get('mode');md.enabled.BOOL=false;return {mode:md,maintenance:false,request:{trigger:'manual'}}}],['maintenance','$maintenance = false',()=>({mode:fixture().store.get('mode'),maintenance:true,request:{trigger:'manual'}})],['approval',"$length($trim($mode.approvalRef.S)) > 0",()=>{const md=fixture().store.get('mode');md.approvalRef.S=' ';return {mode:md,maintenance:false,request:{trigger:'manual'}}}],['expiry',"$toMillis($mode.armedUntil.S) > $millis()",()=>{const md=fixture().store.get('mode');md.armedUntil.S=new Date(fixed-1).toISOString();return {mode:md,maintenance:false,request:{trigger:'manual'}}}],['4h-max',"$toMillis($mode.armedUntil.S) - $millis() <= 14400000",()=>{const md=fixture().store.get('mode');md.armedUntil.S=new Date(fixed+14400001).toISOString();return {mode:md,maintenance:false,request:{trigger:'manual'}}}],['rehearsal-manual',"$request.trigger = 'manual'",()=>({mode:fixture().store.get('mode'),maintenance:false,request:{trigger:'scheduler'}})]];
 for(const[label,part,context]of cases){const bindings=context();assert.equal(await evaluate(arm,bindings,fixed),false);assert.ok(arm.includes(part),part);assert.equal(await evaluate(arm.replace(part,'true'),bindings,fixed),true);killed++;byType['ArmGate-'+label]=(byType['ArmGate-'+label]??0)+1;controls++;}
 // Redrive starts at an external failed Task. Weakening its argument guard must be detected by a bad current context.
 for(const[n,st]of Object.entries(doc.States))if(st.Type==='Task'&&st.Resource.includes('aws-sdk:')&&!/:(get|describe|list|transactWriteItems)/i.test(st.Resource)){
  const first=Object.values(st.Arguments)[0];const b={writeUntil:until,target:SPOT,liveSha:vars.expected_image_sha,states:{context:{Execution:{RedriveCount:1}}}};await assert.rejects(()=>evaluate(first,b,fixed),e=>e.code==='D3141');const mutant=first.replace(/\$assert\([\s\S]+?,'Redriven or expired write Task'\); /,'');assert.notEqual(first,mutant);await evaluate(mutant,b,fixed);killed++;byType['direct-redrive']=(byType['direct-redrive']??0)+1;controls++;
 }
}

// Behavioral mutations of reviewed cross-state recovery and concurrency contracts.
const md=(state='spot-active')=>{const m=fixture().store.get('mode');m.state.S=state;return m};
const req=(extra={})=>({trigger:'manual',scheduledTime:'manual-behavior',...extra});
const td='arn:aws:ecs:ap-northeast-1:111111111111:task-definition/ec-portfolio-demo-api:42';
const ready=(id)=>({pk:{S:'ready#'+id},instanceId:{S:id},sha:{S:vars.expected_image_sha},taskDefinition:{S:td},validUntil:{N:String(fixed+600000)}});
async function behavioral(label,name,factory,input,edit,safety){
 const control=factory(),a=await replay(readDoc(name),control,input,400);await safety(a,control,false);controls++;
 const mutant=readDoc(name);edit(mutant);const m=factory(),b=await replay(mutant,m,input,400);await safety(b,m,true);killed++;byType['behavioral-'+label]=1;
}
await behavioral('close-duplicate','day-close',()=>{const m=fixture({mode:md('off')});m.store.set('run#day-close#manual-behavior',{pk:{S:'run#day-close#manual-behavior'}});return m},req({rdsStop:'self',parkEip:'od'}),doc=>{const tx=doc.States.CloseMode.Arguments.TransactItems;tx.splice(tx.findIndex(x=>x.ConditionCheck?.Key.pk.S.includes('run#day-close')),1)},async(r,m,mut)=>{assert.equal(m.store.get('mode').state.S,mut?'day-close':'off');assert.equal(m.writes.length>0,mut)});
await behavioral('failure-hotloop','od-standby',()=>fixture({mode:md(),holder:'',failAt:'SetDesiredSha',midHook:async(st,m)=>{if(st==='MarkDegraded')m.store.get('mode').enabled.BOOL=false}}),req({action:'prepare'}),doc=>{doc.States.MarkDegraded.Catch[0].Next='Failure'},async(r,m,mut)=>assert.equal(r.status,mut?'LIMIT':'FAIL'));
await behavioral('cooldown-reip','od-standby',()=>fixture({mode:md('od-active'),odState:'running',holder:vars.od_instance_id,desired:1,spots:[SPOT],spotNoPublic:true,day:{pk:{S:'day#2026-10-21'},odDeadline:{N:String(fixed+7200000)},launchWindowStart:{N:String(fixed-1000)},launchCount:{N:'3'},abandonCount:{N:'0'}}}),req({action:'supervise'}),doc=>{doc.States.CooldownReIpGate.Choices[0].Condition='{% true %}'},async(r,m,mut)=>assert.equal(m.writes.some(x=>x.operation==='setDesiredCapacity'),mut));
await behavioral('ready-ttl','ready-check',()=>{const stamp=ready(SPOT);stamp.validUntil.N=String(fixed-1);return fixture({mode:md(),spots:[SPOT],desired:1,holder:SPOT,ready:{[SPOT]:stamp}})},req(),doc=>{const st=doc.States.ReadyChoice.Choices[0];st.Condition=st.Condition.replace('$number($ready.validUntil.N)>$millis()','true')},async(r,m,mut)=>assert.equal(r.status,mut?'PASS':'FAIL'));
await behavioral('holder-event-only','od-standby',()=>{const m=md();m.scope.S='production';delete m.armedUntil;return fixture({mode:m,desired:1,spots:[SPOT],holder:SPOT})},{trigger:'event',scheduledTime:new Date(fixed).toISOString(),event:{id:'MOCK-event-0001',source:'aws.ec2','detail-type':'EC2 Spot Instance Interruption Warning',detail:{'instance-id':'i-99999999999999999'}}},doc=>{doc.States.PrepareGate.Choices[0].Condition='{% true %}'},async(r,m,mut)=>assert.equal(m.writes.some(x=>x.operation==='startInstances'),mut));
await behavioral('first-inservice-settle','od-standby',()=>fixture({mode:md('od-active'),odState:'running',odPublic:true,holder:vars.od_instance_id,spots:[SPOT],desired:1,day:{pk:{S:'day#2026-10-21'},odDeadline:{N:String(fixed+7200000)},odStartedAt:{N:String(fixed-3600001)},starts:{N:'1'},failbacks:{N:'0'}},instanceRecord:{pk:{S:'instance#'+SPOT},firstInServiceAt:{N:String(fixed-1000)}}}),req({action:'supervise'}),doc=>{const st=doc.States.FailbackIdentity.Choices[0];st.Condition=st.Condition.replace('$millis()-$number($failbackRecord.firstInServiceAt.N)>=900000','true')},async(r,m,mut)=>assert.equal(m.writes.some(x=>x.operation==='startExecution'&&JSON.parse(x.args.Input).intent==='failback'),mut));
await behavioral('final-doom-fence','origin-guard',()=>fixture({mode:md(),desired:1,spots:[SPOT],ready:{[SPOT]:ready(SPOT)},midHook:async(st,m)=>{if(st==='FenceAssociate')m.store.set('instance#'+SPOT,{pk:{S:'instance#'+SPOT},interruptionAt:{N:String(m.now)}})}}),req({intent:'promote-spot',target:SPOT}),doc=>{const tx=doc.States.FenceAssociate.Arguments.TransactItems;tx.splice(tx.findIndex(x=>x.ConditionCheck?.Key.pk.S.includes('instance#')),1)},async(r,m,mut)=>assert.equal(m.writes.some(x=>x.operation==='associateAddress'),mut));
await behavioral('approval-reset-no-write','origin-guard',()=>fixture({mode:md(),desired:1,spots:[SPOT],ready:{[SPOT]:ready(SPOT)},midHook:async(st,m)=>{if(st==='FenceAssociate')m.store.get('mode').approvalRef.S='NEW-APPROVAL'}}),req({intent:'promote-spot',target:SPOT}),doc=>{for(const st of Object.values(doc.States))if(st.Resource?.endsWith(':transactWriteItems')){const mo=modeOp(st.Arguments.TransactItems);if(mo)removePart(mo,'approvalRef = :approval');scrub(st.Arguments.TransactItems)}},async(r,m,mut)=>assert.equal(m.writes.some(x=>x.operation==='associateAddress'),mut));

// Reproduce the independently reviewed caught-response-loss -> degraded -> expired-ready boundary on the same store.
{
 const a=await caughtResponseLossFixture(),n=a.writes.length;const r=await replay(readDoc('origin-guard'),a,req({intent:'reconcile',scheduledTime:'manual-lost-response-second'}));assert.equal(r.status,'PASS');assert.ok(a.writes.slice(n).some(x=>x.operation==='startExecution'&&JSON.parse(x.args.Input).reason==='observed-holder-proof-expired'));controls++;
 const doc=readDoc('origin-guard'),c=doc.States.Reconcile.Choices.find(x=>x.Next==='RecoverNeedsProof');assert.ok(c.Condition.includes("['failover-prep','failback','degraded']"));c.Condition=c.Condition.replace("['failover-prep','failback','degraded']","['failover-prep','failback']");const b=await caughtResponseLossFixture(),before=b.writes.length;const result=await replay(doc,b,req({intent:'reconcile',scheduledTime:'manual-lost-response-second'}));assert.equal(result.status,'FAIL');assert.ok(!b.writes.slice(before).some(x=>x.operation==='startExecution'&&JSON.parse(x.args.Input).reason==='observed-holder-proof-expired'));killed++;byType['behavioral-caught-loss-degraded']=1;
}
{
 const a=await caughtResponseLossFixture(),n=a.calls.length;await replay(readDoc('od-standby'),a,req({action:'supervise',reason:'observed-holder-proof-expired'}));assert.ok(a.calls.slice(n).some(x=>x.state==='SuperviseOdReadiness'&&x.args.Parameters.checkMode[0]==='endToEnd'));controls++;
 const doc=readDoc('od-standby');doc.States.SuperviseOdReadiness.Arguments.Parameters.checkMode=['local'];const b=await caughtResponseLossFixture(),before=b.calls.length;await replay(doc,b,req({action:'supervise',reason:'observed-holder-proof-expired'}));assert.ok(!b.calls.slice(before).some(x=>x.state==='SuperviseOdReadiness'&&x.args.Parameters.checkMode[0]==='endToEnd'));killed++;byType['behavioral-caught-loss-e2e-proof']=1;
}
console.log('RESULT: ASL MUTATION PASS '+killed+'/'+killed+' killed; unmutated controls='+controls+'; '+JSON.stringify(byType)+'; real AWS calls=0');
