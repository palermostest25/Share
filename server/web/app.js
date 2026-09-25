const $=s=>document.querySelector(s);
const state={path:'/',entries:[],history:[],sort:'name',ascending:true,key:sessionStorage.getItem('share-key')||'',uploads:0};
const mediaExt=new Set(['mp4','m4v','mov','webm','mp3','m4a','aac','flac','wav','ogg']);
const videoExt=new Set(['mp4','m4v','mov','webm']);

function join(base,name){return (base==='/'?'':base)+'/'+name}
function parent(p){if(p==='/')return '/';const x=p.split('/').filter(Boolean);x.pop();return '/'+x.join('/')}
function ext(name){const i=name.lastIndexOf('.');return i<0?'':name.slice(i+1).toLowerCase()}
function fmtSize(n){if(!n)return '—';const u=['B','KB','MB','GB','TB'];let i=0;while(n>=1024&&i<u.length-1){n/=1024;i++}return `${n.toFixed(i?1:0)} ${u[i]}`}
function fmtDate(s){return new Intl.DateTimeFormat(undefined,{dateStyle:'medium',timeStyle:'short'}).format(new Date(s))}
function icon(e){if(e.type==='dir')return '📁';const x=ext(e.name);if(videoExt.has(x))return '🎬';if(['mp3','m4a','aac','flac','wav','ogg'].includes(x))return '🎵';if(['jpg','jpeg','png','gif','webp','heic'].includes(x))return '🖼️';if(x==='pdf')return '📕';return '📄'}
function message(text){const n=$('#notice');n.textContent=text;n.hidden=!text}

async function api(url,options={}){
  const headers=new Headers(options.headers||{});headers.set('Authorization',`Bearer ${state.key}`);
  if(options.body&&typeof options.body==='string')headers.set('Content-Type','application/json');
  const res=await fetch(url,{...options,headers,cache:'no-store',credentials:'omit'});
  if(res.status===401){lock('Access key rejected.');throw new Error('Access key rejected.')}
  let data=null;const type=res.headers.get('content-type')||'';if(type.includes('json'))data=await res.json();
  if(!res.ok){const err=new Error(data?.message||`Request failed (${res.status})`);err.code=data?.error;err.data=data;throw err}
  return data;
}

function lock(error=''){
  state.key='';sessionStorage.removeItem('share-key');$('#login-error').textContent=error;$('#login-error').hidden=!error;
  if(!$('#login-dialog').open)$('#login-dialog').showModal();setTimeout(()=>$('#access-key').focus(),50)
}

async function load(p=state.path,push=false){
  try{
    message('');if(push&&p!==state.path)state.history.push(state.path);state.path=p;
    const data=await api(`/api/v1/list?path=${encodeURIComponent(p)}`);state.entries=data.entries||[];render();
  }catch(e){if(e.message!=='Access key rejected.')message(e.message)}
}

function render(){
  renderCrumbs();renderFavourites();
  const q=$('#filter').value.toLocaleLowerCase();let rows=state.entries.filter(e=>!q||e.name.toLocaleLowerCase().includes(q));
  rows.sort((a,b)=>{if(a.type!==b.type)return a.type==='dir'?-1:1;let c=0;if(state.sort==='name')c=a.name.localeCompare(b.name,undefined,{numeric:true,sensitivity:'base'});else if(state.sort==='size')c=(a.size||0)-(b.size||0);else c=new Date(a.modified)-new Date(b.modified);return state.ascending?c:-c});
  const body=$('#entries');body.replaceChildren();for(const e of rows)body.append(row(e));
  $('#empty').hidden=rows.length!==0;$('#count').textContent=`${rows.length} item${rows.length===1?'':'s'}`;$('#up').disabled=state.path==='/';$('#back').disabled=!state.history.length;
  const favs=getFavs();$('#favourite-current').textContent=(favs.includes(state.path)?'★ Remove favourite':'☆ Favourite folder');
}

function row(e){
  const tr=document.createElement('tr');tr.className='entry';
  const name=document.createElement('td');const wrap=document.createElement('div');wrap.className='entry-name';
  const ic=document.createElement('span');ic.className='icon';ic.textContent=icon(e);const tx=document.createElement('span');tx.textContent=e.name;wrap.append(ic,tx);name.append(wrap);wrap.ondblclick=()=>openEntry(e);
  const size=document.createElement('td');size.textContent=e.type==='file'?fmtSize(e.size):'—';
  const date=document.createElement('td');date.textContent=fmtDate(e.modified);
  const actions=document.createElement('td');const box=document.createElement('div');box.className='row-actions';
  const open=button('Open',()=>openEntry(e));const rename=button('Rename',()=>renameEntry(e));const del=button('Delete',()=>deleteEntry(e));box.append(open,rename,del);actions.append(box);tr.append(name,size,date,actions);return tr;
}
function button(text,fn){const b=document.createElement('button');b.textContent=text;b.onclick=fn;return b}

function renderCrumbs(){
  const c=$('#breadcrumbs');c.replaceChildren();const parts=state.path.split('/').filter(Boolean);const root=button('Share',()=>load('/',true));c.append(root);let p='';for(const part of parts){const sep=document.createElement('span');sep.textContent='›';p+='/'+part;const dest=p;const b=button(part,()=>load(dest,true));c.append(sep,b)}
}

async function signed(p){const d=await api('/api/v1/link',{method:'POST',body:JSON.stringify({path:p})});return new URL(d.url,location.origin).href}
async function openEntry(e){
  if(e.type==='dir'){await load(join(state.path,e.name),true);return}
  try{const url=await signed(join(state.path,e.name));const x=ext(e.name);if(mediaExt.has(x)){const video=$('#video'),audio=$('#audio');$('#media-title').textContent=e.name;if(videoExt.has(x)){audio.hidden=true;video.hidden=false;video.src=url;await video.play().catch(()=>{})}else{video.hidden=true;audio.hidden=false;audio.src=url;await audio.play().catch(()=>{})}$('#media-dialog').showModal()}else{window.open(url,'_blank','noopener')}}catch(err){message(err.message)}
}

async function renameEntry(e){const next=prompt('New name',e.name);if(!next||next===e.name)return;try{await api('/api/v1/move',{method:'POST',body:JSON.stringify({from:join(state.path,e.name),to:join(state.path,next.normalize('NFC')),overwrite:false})});await load()}catch(err){message(err.message)}}
async function deleteEntry(e){
  $('#confirm-title').textContent=`Delete ${e.name}?`;$('#confirm-text').textContent="It will be gone for both people. ZFS snapshots are the recovery path.";const d=$('#confirm-dialog');d.showModal();
  if(await new Promise(resolve=>d.addEventListener('close',()=>resolve(d.returnValue==='ok'),{once:true}))){try{await api(`/api/v1/entry?path=${encodeURIComponent(join(state.path,e.name))}`,{method:'DELETE'});await load()}catch(err){message(err.message)}}
}
async function newFolder(){const name=prompt('Folder name','untitled folder');if(!name)return;try{await api('/api/v1/mkdir',{method:'POST',body:JSON.stringify({path:join(state.path,name.normalize('NFC'))})});await load()}catch(err){message(err.message)}}

function getFavs(){try{return JSON.parse(localStorage.getItem('share-favourites')||'[]')}catch{return []}}
function setFavs(v){localStorage.setItem('share-favourites',JSON.stringify(v));renderFavourites()}
function renderFavourites(){const box=$('#favourites');box.replaceChildren();for(const p of getFavs()){const b=button('★ '+(p==='/'?'Share':p.split('/').pop()),()=>load(p,true));b.className='side';b.title=p;box.append(b)}}
function toggleFavourite(){let f=getFavs();f=f.includes(state.path)?f.filter(x=>x!==state.path):[...f,state.path];setFavs([...new Set(f)]);render()}

async function uploadFiles(files){
  if(!files.length)return;$('#transfers').hidden=false;
  const destination=state.path;
  const queue=[...files].map(file=>transferJob(file,destination));
  const workers=[worker(queue),worker(queue)];await Promise.all(workers);await load();
}
function transferJob(file,destination){
  const controller=new AbortController(),item=document.createElement('div'),head=document.createElement('div'),name=document.createElement('strong'),cancel=button('Cancel',()=>{controller.abort();cancel.disabled=true;detail.textContent='Cancelling…'}),detail=document.createElement('small'),bar=document.createElement('div'),fill=document.createElement('i');
  item.className='transfer';head.className='transfer-head';name.className='transfer-name';name.textContent=file.name;cancel.className='transfer-cancel';detail.textContent=`Waiting · ${fmtSize(file.size)}`;bar.className='bar';bar.append(fill);head.append(name,cancel);item.append(head,bar,detail);$('#transfer-list').prepend(item);
  return {file,destination,controller,name,cancel,detail,fill};
}
async function worker(queue){while(queue.length){const job=queue.shift();if(!job.controller.signal.aborted)await uploadOne(job);else{job.detail.textContent='Cancelled';job.name.textContent=`× ${job.file.name}`;job.cancel.remove()}}}
async function uploadOne(job){
  const {file,destination,controller,name,cancel,detail,fill}=job;state.uploads++;let uploadID=null;
  try{
    const target=join(destination,file.name.normalize('NFC'));let overwrite=false,start;
    detail.textContent=`Starting · ${fmtSize(file.size)}`;
    try{start=await api('/api/v1/uploads',{method:'POST',signal:controller.signal,body:JSON.stringify({path:target,size:file.size,modified:new Date(file.lastModified).toISOString(),overwrite:false})})}
    catch(e){if(e.code!=='exists'||!confirm(`${file.name} exists. Replace it?`))throw e;overwrite=true;start=await api('/api/v1/uploads',{method:'POST',signal:controller.signal,body:JSON.stringify({path:target,size:file.size,modified:new Date(file.lastModified).toISOString(),overwrite})})}
    uploadID=start.id;let offset=start.received;const began=performance.now();
    while(offset<file.size){
      if(controller.signal.aborted)throw new DOMException('Cancelled','AbortError');
      const end=Math.min(offset+start.chunkSize,file.size),chunk=file.slice(offset,end);let tries=0;
      for(;;){
        try{const d=await api(`/api/v1/uploads/${start.id}?offset=${offset}`,{method:'PUT',signal:controller.signal,body:chunk,headers:{'Content-Type':'application/octet-stream'}});offset=d.received;break}
        catch(e){if(controller.signal.aborted)throw e;if(e.code==='offset_mismatch'){offset=e.data.received;break}if(++tries>=10)throw e;await new Promise(r=>setTimeout(r,Math.min(30000,1000*2**(tries-1))))}
      }
      fill.style.width=`${file.size?offset/file.size*100:100}%`;
      const speed=offset/Math.max((performance.now()-began)/1000,.1),remaining=speed>0?Math.ceil((file.size-offset)/speed):0;
      detail.textContent=`${fmtSize(offset)} of ${fmtSize(file.size)} · ${fmtSize(speed)}/s · ${remaining<60?`${remaining}s`:`${Math.floor(remaining/60)}m ${remaining%60}s`} left`;
    }
    await api(`/api/v1/uploads/${start.id}/complete`,{method:'POST',signal:controller.signal});uploadID=null;
    name.textContent=`✓ ${file.name}`;detail.textContent='Complete';cancel.remove();fill.style.width='100%';
  }catch(e){
    if(uploadID)await api(`/api/v1/uploads/${uploadID}`,{method:'DELETE'}).catch(()=>{});
    if(controller.signal.aborted){detail.textContent='Cancelled';name.textContent=`× ${file.name}`}
    else{detail.textContent=`Failed: ${e.message}`;message(`${file.name}: ${e.message}`)}
    cancel.remove();
  }finally{state.uploads--}
}

$('#login-form').addEventListener('submit',async e=>{e.preventDefault();state.key=$('#access-key').value;try{await api('/api/v1/list?path=%2F');sessionStorage.setItem('share-key',state.key);$('#login-dialog').close();$('#login-error').hidden=true;await load('/')}catch(err){if(err.message!=='Access key rejected.'){ $('#login-error').textContent=err.message;$('#login-error').hidden=false }}});
$('#back').onclick=()=>{const p=state.history.pop();if(p)load(p)};$('#up').onclick=()=>load(parent(state.path),true);$('#refresh').onclick=()=>load();$('#new-folder').onclick=newFolder;$('#upload-input').onchange=e=>{uploadFiles(e.target.files);e.target.value=''};$('#logout').onclick=()=>lock();$('#filter').oninput=render;$('#favourite-current').onclick=toggleFavourite;$('#all-files').onclick=()=>load('/',true);
document.querySelectorAll('th[data-sort]').forEach(th=>th.onclick=()=>{const s=th.dataset.sort;if(state.sort===s)state.ascending=!state.ascending;else{state.sort=s;state.ascending=true}render()});
$('#media-close').onclick=()=>$('#media-dialog').close();$('#media-dialog').addEventListener('close',()=>{for(const el of [$('#video'),$('#audio')]){el.pause();el.removeAttribute('src');el.load()}});
const dz=$('#drop-zone');for(const ev of ['dragenter','dragover'])dz.addEventListener(ev,e=>{e.preventDefault();dz.classList.add('dragging')});for(const ev of ['dragleave','drop'])dz.addEventListener(ev,e=>{e.preventDefault();dz.classList.remove('dragging')});dz.addEventListener('drop',e=>uploadFiles(e.dataTransfer.files));
window.addEventListener('focus',()=>state.key&&load());setInterval(()=>{if(!document.hidden&&state.key)load()},30000);
if(state.key)load();else lock();
