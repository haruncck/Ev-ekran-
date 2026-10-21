/* Network first, cache fallback, so the form opens and the PDF builds even without signal. */
const C="bakim-v2";
const FILES=["./","./index.html","./logo.png","./icon.png","./manifest.json","./lib/jspdf.umd.min.js","./lib/sans-Regular.ttf","./lib/sans-Bold.ttf"];
self.addEventListener("install",e=>{e.waitUntil(caches.open(C).then(c=>c.addAll(FILES)));self.skipWaiting()});
self.addEventListener("activate",e=>{e.waitUntil(caches.keys().then(ks=>Promise.all(ks.filter(k=>k!==C).map(k=>caches.delete(k)))).then(()=>self.clients.claim()))});
self.addEventListener("fetch",e=>{
  if(e.request.method!=="GET"||new URL(e.request.url).origin!==location.origin)return;
  e.respondWith(fetch(e.request).then(r=>{if(r.ok){const cp=r.clone();caches.open(C).then(c=>c.put(e.request,cp))}return r}).catch(()=>caches.match(e.request,{ignoreSearch:true}).then(m=>m||caches.match("./index.html"))));
});
