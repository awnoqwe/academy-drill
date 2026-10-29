// 아페라 푸시 서버: 일정(학생) · 시간표(학생+학부모) · 알림장(학부모)
// 학원 구성원(원장·선생님)이나 운영자만 보낼 수 있고, 보낸 사람이 속한 학원의 것만 보낸다.
import {createClient} from 'npm:@supabase/supabase-js@2.49.4';
import webpush from 'npm:web-push@3.6.7';
const project=Deno.env.get('SUPABASE_URL')!;
const service=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const origin='https://awnoqwe.github.io';
const appUrl='https://awnoqwe.github.io/academy-drill/';
const cors={'Access-Control-Allow-Origin':origin,'Access-Control-Allow-Headers':'authorization, x-client-info, apikey, content-type','Access-Control-Allow-Methods':'POST, OPTIONS','Vary':'Origin'};
const admin=createClient(project,service,{auth:{persistSession:false,autoRefreshToken:false}});
const response=(data:unknown,status=200)=>new Response(JSON.stringify(data),{status,headers:{...cors,'Content-Type':'application/json'}});
const allowedEndpoint=(endpoint:string)=>{try{const u=new URL(endpoint);return u.protocol==='https:'&&!u.port&&!u.username&&!u.password&&(/^(fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|web\.push\.apple\.com|[a-z0-9-]+\.notify\.windows\.com)$/.test(u.hostname))}catch{return false}};
const uuid=(x:unknown)=>typeof x==='string'&&/^[0-9a-f-]{36}$/i.test(x);
async function config(){let {data,error}=await admin.from('drill_push_config').select('*').eq('id',1).maybeSingle();if(error)throw error;if(!data){const keys=webpush.generateVAPIDKeys();const insert=await admin.from('drill_push_config').upsert({id:1,public_key:keys.publicKey,private_key:keys.privateKey},{onConflict:'id',ignoreDuplicates:true});if(insert.error)throw insert.error;const read=await admin.from('drill_push_config').select('*').eq('id',1).single();if(read.error)throw read.error;data=read.data}return data}
async function canSend(userId:string,academyId:string){
 const a=await admin.from('platform_admins').select('user_id').eq('user_id',userId).maybeSingle();if(a.data)return true;
 const m=await admin.from('academy_members').select('user_id').eq('user_id',userId).eq('academy_id',academyId).maybeSingle();return !!m.data;
}
const fmtDay=(d:string)=>{const t=new Date(d+'T00:00:00Z');return `${t.getUTCMonth()+1}/${t.getUTCDate()}(${'일월화수목금토'[t.getUTCDay()]})`;};
type Job={message:string,kind:'student'|'parent',sub:any,payload:Record<string,unknown>};

Deno.serve(async(req)=>{
 if(req.method==='OPTIONS')return new Response('ok',{headers:cors});
 if(req.method!=='POST')return response({error:'method_not_allowed'},405);
 try{
  let body;try{body=await req.json()}catch{return response({error:'invalid_json'},400)}
  if(body.action==='setup'){const keys=await config();return response({ready:true,publicKey:keys.public_key})}
  const token=(req.headers.get('Authorization')||'').replace(/^Bearer\s+/i,'');
  const {data:user,error:authError}=await admin.auth.getUser(token);
  if(authError||!user?.user)return response({error:'unauthorized'},401);
  const uid=user.user.id;
  const keys=await config();
  const jobs:Job[]=[];
  // 무엇을 보낼지 정리: (학원, 받는 학생, 학부모에게도?, 제목·본문)
  if(body.action==='send'){ // 예전 방식: 일정
   if(!Array.isArray(body.eventIds)||body.eventIds.length<1||body.eventIds.length>100||!body.eventIds.every(uuid))return response({error:'invalid_events'},400);
   body={action:'push',kind:'event',ids:body.eventIds};
  }
  if(body.action!=='push'||!['event','timetable','notice'].includes(body.kind)||!Array.isArray(body.ids)||body.ids.length<1||body.ids.length>100||!body.ids.every(uuid))return response({error:'invalid_request'},400);
  const ids=[...new Set(body.ids as string[])];
  const targets:{message:string,students:string[],toStudents:boolean,toParents:boolean,title:string,text:string,view:string}[]=[];
  if(body.kind==='event'){
   const {data,error}=await admin.from('drill_events').select('id,academy_id,title').in('id',ids);if(error)throw error;
   for(const e of data){ if(!await canSend(uid,e.academy_id))return response({error:'forbidden'},403);
    const r=await admin.from('drill_event_recipients').select('student_id').eq('event_id',e.id);if(r.error)throw r.error;
    targets.push({message:'event:'+e.id,students:r.data.map(x=>x.student_id),toStudents:true,toParents:false,title:'아페라 · 새 일정',text:e.title||'새 일정이 도착했어요.',view:'notifications'}); }
  }
  if(body.kind==='timetable'){
   const {data,error}=await admin.from('timetables').select('id,academy_id,kind,weekday,date_from,date_to,title,cells,updated_at').in('id',ids);if(error)throw error;
   for(const t of data){ if(!await canSend(uid,t.academy_id))return response({error:'forbidden'},403);
    const classes=Object.keys(t.cells||{}).filter(uuid);
    const s=classes.length?await admin.from('students').select('id').eq('academy_id',t.academy_id).eq('approved',true).in('class_id',classes):{data:[],error:null};if(s.error)throw s.error;
    const when=t.kind==='weekly'?`${'월화수목금토일'[t.weekday]}요일 고정`:(t.date_from===t.date_to?fmtDay(t.date_from):`${fmtDay(t.date_from)}~${fmtDay(t.date_to)}`);
    targets.push({message:'timetable:'+t.id+':'+t.updated_at,students:s.data.map((x:any)=>x.id),toStudents:true,toParents:true,title:'아페라 · 시간표',text:`${when} 시간표가 ${t.kind==='weekly'?'바뀌었어요':'나왔어요'}. ${t.title||''}`.trim(),view:'timetable'}); }
  }
  if(body.kind==='notice'){
   const {data,error}=await admin.from('notices').select('id,academy_id,title').in('id',ids);if(error)throw error;
   for(const n of data){ if(!await canSend(uid,n.academy_id))return response({error:'forbidden'},403);
    const r=await admin.from('notice_recipients').select('student_id').eq('notice_id',n.id);if(r.error)throw r.error;
    targets.push({message:'notice:'+n.id,students:r.data.map(x=>x.student_id),toStudents:false,toParents:true,title:'아페라 · 알림장',text:n.title,view:'parent'}); }
  }
  if(!targets.length)return response({error:'not_found'},404);
  for(const t of targets){
   if(!t.students.length)continue;
   if(t.toStudents){
    const {data,error}=await admin.from('drill_push_subscriptions').select('*').in('student_id',t.students).eq('active',true);if(error)throw error;
    for(const s of data)jobs.push({message:t.message,kind:'student',sub:s,payload:{title:t.title,body:t.text,studentId:s.student_id,url:appUrl+'?view='+t.view}});
   }
   if(t.toParents){
    const pc=await admin.from('parent_children').select('code').in('student_id',t.students);if(pc.error)throw pc.error;
    const codes=[...new Set(pc.data.map(x=>x.code))];
    if(codes.length){const {data,error}=await admin.from('parent_push_subscriptions').select('*').in('code',codes).eq('active',true);if(error)throw error;
     // 같은 기기가 코드 여러 개로 구독했으면 한 번만
     const seen=new Set<string>();
     for(const s of data){ if(seen.has(s.endpoint))continue; seen.add(s.endpoint); jobs.push({message:t.message,kind:'parent',sub:s,payload:{title:t.title,body:t.text,parentCode:s.code,url:appUrl+'?view=parent'}}); }}
   }
  }
  let sent=0,failed=0,expired=0,skipped=0,cursor=0;
  await Promise.all(Array.from({length:Math.min(6,jobs.length)},async()=>{while(cursor<jobs.length){const job=jobs[cursor++],s=job.sub;
   const {data:claimed,error:claimError}=await admin.rpc('push_claim',{p_message:job.message,p_kind:job.kind,p_sub:s.id});if(claimError){failed++;continue}if(!claimed){skipped++;continue}
   let status='failed';
   try{
    if(!allowedEndpoint(s.endpoint))throw Error('invalid_endpoint');
    const details=webpush.generateRequestDetails({endpoint:s.endpoint,keys:{p256dh:s.p256dh,auth:s.auth}},JSON.stringify({...job.payload,tag:job.message}),{TTL:86400,urgency:'normal',vapidDetails:{subject:appUrl,publicKey:keys.public_key,privateKey:keys.private_key}});
    const result=await fetch(details.endpoint,{method:details.method,headers:details.headers,body:details.body,redirect:'error',signal:AbortSignal.timeout(10000)});
    await result.body?.cancel();
    if(result.ok){sent++;status='sent'}else if(result.status===404||result.status===410){expired++;status='expired';await admin.from(job.kind==='student'?'drill_push_subscriptions':'parent_push_subscriptions').update({active:false}).eq('id',s.id)}else{failed++}
   }catch{failed++}
   await admin.from('push_sent').update({status,updated_at:new Date().toISOString()}).eq('message',job.message).eq('sub_kind',job.kind).eq('sub_id',s.id);
  }}));
  return response({sent,failed,expired,skipped,subscribed:jobs.length});
 }catch{return response({error:'push_server_error'},500)}
});
