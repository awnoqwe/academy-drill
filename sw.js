'use strict';
// 푸시 알림 + 앱 화면 저장(오프라인 실행).
// 앱 화면(index.html)은 항상 인터넷에서 먼저 받고, 안 될 때만 저장본을 쓴다 → 업데이트는 바로 반영된다.
// 서버(Supabase) 요청은 가로채지 않는다. 글꼴·서버 연결 프로그램만 저장본을 먼저 쓰고 뒤에서 새로 받는다.
const SHELL='apera-shell-v1';
const SHELL_FILES=['./','./index.html','./manifest.webmanifest','./icon-192.png','./apple-touch-icon.png','./favicon-32.png'];
const SHARED=/^https:\/\/(cdn\.jsdelivr\.net\/npm\/@supabase\/|fonts\.googleapis\.com\/|fonts\.gstatic\.com\/)/;
const DB='trigger-push-device-v1';
function deviceStore(mode,action){return new Promise((resolve,reject)=>{const open=indexedDB.open(DB,1);open.onupgradeneeded=()=>open.result.createObjectStore('settings');open.onerror=()=>reject(open.error);open.onsuccess=()=>{const db=open.result,tx=db.transaction('settings',mode),req=action(tx.objectStore('settings'));let value;req.onsuccess=()=>value=req.result;tx.oncomplete=()=>{db.close();resolve(value)};tx.onerror=()=>{db.close();reject(tx.error)}}})}
self.addEventListener('install',event=>{self.skipWaiting();event.waitUntil(caches.open(SHELL).then(c=>c.addAll(SHELL_FILES)).catch(()=>{}))});
self.addEventListener('activate',event=>event.waitUntil((async()=>{const keys=await caches.keys();await Promise.all(keys.filter(k=>k.startsWith('apera-shell-')&&k!==SHELL).map(k=>caches.delete(k)));await self.clients.claim()})()));
self.addEventListener('fetch',event=>{const req=event.request;if(req.method!=='GET')return;const url=new URL(req.url);
 if(url.origin===self.location.origin){
  if(req.mode==='navigate'||url.pathname.endsWith('/index.html')){event.respondWith((async()=>{try{const res=await fetch(req);if(res.ok){const c=await caches.open(SHELL);c.put('./index.html',res.clone())}return res}catch(e){return (await caches.match('./index.html'))||(await caches.match('./'))||Response.error()}})());return}
  if(/\.(png|webmanifest)$/.test(url.pathname)){event.respondWith((async()=>{const hit=await caches.match(req);const net=fetch(req).then(res=>{if(res.ok)caches.open(SHELL).then(c=>c.put(req,res.clone()));return res}).catch(()=>hit);return hit||net})());}
  return}
 if(SHARED.test(req.url)){event.respondWith((async()=>{const hit=await caches.match(req);const net=fetch(req).then(res=>{if(res.ok||res.type==='opaque')caches.open(SHELL).then(c=>c.put(req,res.clone()));return res}).catch(()=>hit);return hit||net})())}
});
self.addEventListener('message',event=>{if(event.data?.type==='PUSH_OWNER'){event.waitUntil(deviceStore('readwrite',s=>s.put(event.data.studentId||null,'studentId')).then(()=>event.ports[0]?.postMessage({ok:true})).catch(()=>event.ports[0]?.postMessage({ok:false})))}});
self.addEventListener('push',event=>event.waitUntil((async()=>{let data;try{data=event.data?.json()}catch{return}if(!data?.studentId)return;const owner=await deviceStore('readonly',s=>s.get('studentId'));if(owner!==data.studentId)return;await self.registration.showNotification('아페라 · 새 일정',{body:'새 일정이 도착했어요. 앱에서 확인해주세요.',icon:new URL('icon-192.png',self.registration.scope).href,badge:new URL('favicon-32.png',self.registration.scope).href,tag:'schedule-'+data.eventId,data:{url:new URL('?view=notifications',self.registration.scope).href},renotify:false});})()));
self.addEventListener('notificationclick',event=>{event.notification.close();event.waitUntil((async()=>{const url=new URL('?view=notifications',self.registration.scope).href;const windows=await self.clients.matchAll({type:'window',includeUncontrolled:true});for(const client of windows){if(client.url.startsWith(self.registration.scope)){await client.navigate(url);return client.focus()}}return self.clients.openWindow(url)})())});
