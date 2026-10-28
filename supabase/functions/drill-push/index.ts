import {createClient} from 'npm:@supabase/supabase-js@2.49.4';
import webpush from 'npm:web-push@3.6.7';
const project=Deno.env.get('SUPABASE_URL')!;
const service=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const origin='https://awnoqwe.github.io';
const cors={'Access-Control-Allow-Origin':origin,'Access-Control-Allow-Headers':'authorization, x-client-info, apikey, content-type','Access-Control-Allow-Methods':'POST, OPTIONS','Vary':'Origin'};
const admin=createClient(project,service,{auth:{persistSession:false,autoRefreshToken:false}});
const response=(data:unknown,status=200)=>new Response(JSON.stringify(data),{status,headers:{...cors,'Content-Type':'application/json'}});
const allowedEndpoint=(endpoint:string)=>{try{let u=new URL(endpoint);return u.protocol==='https:'&&!u.port&&!u.username&&!u.password&&(/^(fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|web\.push\.apple\.com|[a-z0-9-]+\.notify\.windows\.com)$/.test(u.hostname))}catch{return false}};
async function config(){let {data,error}=await admin.from('drill_push_config').select('*').eq('id',1).maybeSingle();if(error)throw error;if(!data){const keys=webpush.generateVAPIDKeys();let insert=await admin.from('drill_push_config').upsert({id:1,public_key:keys.publicKey,private_key:keys.privateKey},{onConflict:'id',ignoreDuplicates:true});if(insert.error)throw insert.error;let read=await admin.from('drill_push_config').select('*').eq('id',1).single();if(read.error)throw read.error;data=read.data}return data}
Deno.serve(async(req)=>{
 if(req.method==='OPTIONS')return new Response('ok',{headers:cors});
 if(req.method!=='POST')return response({error:'method_not_allowed'},405);
 try{
  const authorization=req.headers.get('Authorization')||'';
  let body;try{body=await req.json()}catch{return response({error:'invalid_json'},400)}
  // Public setup only generates a single server-owned key pair and exposes its public half.
  if(body.action==='setup'){const keys=await config();return response({ready:true,publicKey:keys.public_key})}
  const token=authorization.replace(/^Bearer\s+/i,'');
  const {data:user,error:authError}=await admin.auth.getUser(token);
  if(authError||!user?.user)return response({error:'unauthorized'},401);
  const {data:teacher,error:teacherError}=await admin.from('teachers').select('user_id').eq('user_id',user.user.id).maybeSingle();
  if(teacherError||!teacher)return response({error:'teacher_only'},403);
  const keys=await config();
  if(body.action==='setup')return response({ready:true,publicKey:keys.public_key});
  if(body.action!=='send'||!Array.isArray(body.eventIds)||body.eventIds.length<1||body.eventIds.length>100||body.eventIds.some((id:unknown)=>typeof id!=='string'||!/^[0-9a-f-]{36}$/i.test(id)))return response({error:'invalid_events'},400);
  const {data:events,error:eventsError}=await admin.from('drill_events').select('id,type').in('id',[...new Set(body.eventIds)]);
  if(eventsError)throw eventsError;
  const eventIds=events.map(e=>e.id);
  if(!eventIds.length)return response({error:'no_events'},404);
  const {data:recipients,error:rError}=await admin.from('drill_event_recipients').select('event_id,student_id').in('event_id',eventIds);
  if(rError)throw rError;
  const students=[...new Set(recipients.map(r=>r.student_id))];
  if(!students.length)return response({sent:0,failed:0,expired:0,skipped:0,subscribed:0});
  const {data:subscriptions,error:sError}=await admin.from('drill_push_subscriptions').select('*').in('student_id',students).eq('active',true);
  if(sError)throw sError;
  let sent=0,failed=0,expired=0,skipped=0;
  const jobs=recipients.flatMap(r=>subscriptions.filter(s=>s.student_id===r.student_id).map(s=>({eventId:r.event_id,subscription:s})));
  let cursor=0;
  await Promise.all(Array.from({length:Math.min(6,jobs.length)},async()=>{while(cursor<jobs.length){const job=jobs[cursor++],s=job.subscription;
   const {data:claimed,error:claimError}=await admin.rpc('drill_push_claim',{p_event:job.eventId,p_subscription:s.id});if(claimError){failed++;continue}if(!claimed){skipped++;continue}
   let status='failed';
   try{
    if(!allowedEndpoint(s.endpoint))throw Error('invalid_endpoint');
    const details=webpush.generateRequestDetails({endpoint:s.endpoint,keys:{p256dh:s.p256dh,auth:s.auth}},JSON.stringify({title:'아페라 · 새 일정',body:'새 일정이 도착했어요. 앱에서 확인해주세요.',eventId:job.eventId,studentId:s.student_id,url:'https://awnoqwe.github.io/academy-drill/?view=notifications'}),{TTL:86400,urgency:'normal',vapidDetails:{subject:'https://awnoqwe.github.io/academy-drill/',publicKey:keys.public_key,privateKey:keys.private_key}});
    const result=await fetch(details.endpoint,{method:details.method,headers:details.headers,body:details.body,redirect:'error',signal:AbortSignal.timeout(10000)});
    await result.body?.cancel();
    if(result.ok){sent++;status='sent'}else if(result.status===404||result.status===410){expired++;status='expired';await admin.from('drill_push_subscriptions').update({active:false}).eq('id',s.id)}else{failed++}
   }catch{failed++}
   await admin.from('drill_push_deliveries').update({status,updated_at:new Date().toISOString()}).eq('event_id',job.eventId).eq('subscription_id',s.id);
  }}));
  return response({sent,failed,expired,skipped,subscribed:subscriptions.length});
 }catch{return response({error:'push_server_error'},500)}
});
