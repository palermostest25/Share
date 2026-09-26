const $=s=>document.querySelector(s);
const state={path:'/',entries:[],history:[],sort:'name',ascending:true,key:sessionStorage.getItem('share-token')||'',uploads:0,user:null,needsSetup:false,dragDepth:0};
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
  if(res.status===401){lock('Session expired or credentials rejected.');throw new Error('Session expired or credentials rejected.')}
  let data=null;const type=res.headers.get('content-type')||'';if(type.includes('json'))data=await res.json();
  if(!res.ok){const err=new Error(data?.message||`Request failed (${res.status})`);err.code=data?.error;err.data=data;throw err}
  return data;
}

function lock(error=''){
	state.key='';state.user=null;sessionStorage.removeItem('share-token');$('#login-error').textContent=error;$('#login-error').hidden=!error;
	if(!$('#login-dialog').open)$('#login-dialog').showModal();setTimeout(()=>$('#username').focus(),50)
}

async function load(p=state.path,push=false){
  try{
    message('');if(push&&p!==state.path)state.history.push(state.path);state.path=p;
    const data=await api(`/api/v1/list?path=${encodeURIComponent(p)}`);state.entries=data.entries||[];render();document.querySelector('aside').classList.remove('mobile-open');
  }catch(e){if(e.message!=='Session expired or credentials rejected.')message(e.message)}
}

function render(){
  renderCrumbs();renderFavourites();
  const q=$('#filter').value.toLocaleLowerCase();let rows=state.entries.filter(e=>!q||e.name.toLocaleLowerCase().includes(q));
  rows.sort((a,b)=>{if(a.type!==b.type)return a.type==='dir'?-1:1;let c=0;if(state.sort==='name')c=a.name.localeCompare(b.name,undefined,{numeric:true,sensitivity:'base'});else if(state.sort==='size')c=(a.size||0)-(b.size||0);else c=new Date(a.modified)-new Date(b.modified);return state.ascending?c:-c});
  const body=$('#entries');body.replaceChildren();for(const e of rows)body.append(row(e));
  $('#empty').hidden=rows.length!==0;$('#count').textContent=`${rows.length} item${rows.length===1?'':'s'}`;$('#up').disabled=state.path==='/';$('#back').disabled=!state.history.length;
	const favs=getFavs();$('#favourite-current').textContent=(favs.includes(state.path)?'★ Remove favourite':'☆ Favourite folder');
	$('#new-folder').disabled=!canWrite(state.path);$('#mobile-new-folder').disabled=!canWrite(state.path);$('#upload-input').disabled=!canWrite(state.path);$('#mobile-upload-label').setAttribute('aria-disabled',String(!canWrite(state.path)));$('#admin').hidden=!state.user?.admin;$('#mobile-admin').hidden=!state.user?.admin;
	$('#mobile-favourite-current').textContent=favs.includes(state.path)?'Remove favourite':'Favourite this folder';
}

function canWrite(p){return !!state.user?.admin||!!state.user?.grants?.some(g=>g.write&&(p===g.path||p.startsWith(g.path+'/')))}

function row(e){
	const tr=document.createElement('tr');tr.className='entry';tr.draggable=true;tr.tabIndex=0;
  const name=document.createElement('td');const wrap=document.createElement('div');wrap.className='entry-name';
	const ic=document.createElement('span');ic.className='icon';ic.textContent=icon(e);const tx=document.createElement('span');tx.textContent=e.name;wrap.append(ic,tx);name.append(wrap);
    const meta=document.createElement('small');meta.className='entry-meta';meta.textContent=e.type==='file'?`${fmtSize(e.size)} · ${fmtDate(e.modified)}`:`Folder · ${fmtDate(e.modified)}`;name.append(meta);
  const size=document.createElement('td');size.textContent=e.type==='file'?fmtSize(e.size):'—';
  const date=document.createElement('td');date.textContent=fmtDate(e.modified);
  const actions=document.createElement('td');const box=document.createElement('div');box.className='row-actions';
	const open=button('Open',()=>openEntry(e));const more=button('⋯',ev=>{ev.stopPropagation();showMenu(ev,e)});more.setAttribute('aria-label',`More actions for ${e.name}`);box.append(open,more);actions.append(box);tr.append(name,size,date,actions);
	wrap.onclick=()=>{if(matchMedia('(max-width:760px)').matches)openEntry(e)};
	tr.ondblclick=()=>{if(!matchMedia('(max-width:760px)').matches)openEntry(e)};tr.onkeydown=ev=>{if(ev.key==='Enter'){ev.preventDefault();openEntry(e)}else if(ev.key===' '){ev.preventDefault();openEntry(e)}};
	tr.oncontextmenu=ev=>{ev.preventDefault();showMenu(ev,e)};
	tr.ondragstart=ev=>{ev.dataTransfer.setData('application/x-share-entry',join(state.path,e.name));ev.dataTransfer.effectAllowed='move'};
	if(e.type==='dir'){tr.ondragover=ev=>{ev.preventDefault();tr.classList.add('drop-target')};tr.ondragleave=()=>tr.classList.remove('drop-target');tr.ondrop=async ev=>{ev.preventDefault();ev.stopPropagation();tr.classList.remove('drop-target');const source=ev.dataTransfer.getData('application/x-share-entry');const target=join(state.path,e.name);if(source){await movePath(source,join(target,source.split('/').pop()))}else if(ev.dataTransfer.files.length){await uploadFiles(await filesFromDrop(ev.dataTransfer),target)}}}
	return tr;
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

function showMenu(ev,e){
	const menu=$('#context-menu');menu.replaceChildren();const p=join(state.path,e.name);
	const add=(label,fn)=>{const b=button(label,()=>{menu.hidden=true;fn()});b.setAttribute('role','menuitem');menu.append(b)};
	add(e.type==='dir'?'Open folder':'Open / preview',()=>openEntry(e));
	if(e.type==='file'){add('Download',()=>downloadEntry(e));add('Copy share link',()=>copyLink(e))}
	if(state.user?.admin)add('Share with person',()=>shareEntry(e));
	if(canWrite(p)){add('Rename',()=>renameEntry(e));add('Move to folder…',()=>moveEntry(e));add('Delete',()=>deleteEntry(e))}
	menu.hidden=false;const mobile=matchMedia('(max-width:760px)').matches;menu.classList.toggle('mobile-sheet',mobile);
    if(mobile){menu.style.left='8px';menu.style.top='auto';menu.style.bottom='calc(72px + env(safe-area-inset-bottom))';return}
    menu.style.bottom='auto';const x=ev.clientX??ev.currentTarget?.getBoundingClientRect().left??0,y=ev.clientY??ev.currentTarget?.getBoundingClientRect().bottom??0;
	menu.style.left=`${Math.max(8,Math.min(x,innerWidth-menu.offsetWidth-8))}px`;menu.style.top=`${Math.max(8,Math.min(y,innerHeight-menu.offsetHeight-8))}px`;
}
document.addEventListener('click',ev=>{if(!$('#context-menu').contains(ev.target))$('#context-menu').hidden=true});
document.addEventListener('keydown',ev=>{if(ev.key==='Escape')$('#context-menu').hidden=true});

async function downloadEntry(e){try{const a=document.createElement('a');a.href=await signed(join(state.path,e.name));a.download=e.name;document.body.append(a);a.click();a.remove()}catch(err){message(err.message)}}
async function copyLink(e){try{const url=await signed(join(state.path,e.name));if(navigator.clipboard?.writeText)await navigator.clipboard.writeText(url);else{const input=document.createElement('textarea');input.value=url;document.body.append(input);input.select();const copied=document.execCommand('copy');input.remove();if(!copied){await askText('Copy share link',url,'Select and copy this link. It expires in 12 hours.');return}}message('Link copied. It expires in 12 hours and anyone with it can access this file.')}catch(err){message(err.message)}}

function askText(title,value='',help='',secret=false){
	return new Promise(resolve=>{const d=$('#text-dialog'),input=$('#text-value');$('#text-title').textContent=title;$('#text-help').textContent=help;input.type=secret?'password':'text';input.value=value;d.returnValue='cancel';d.showModal();input.focus();input.select();d.addEventListener('close',()=>resolve(d.returnValue==='ok'?input.value.trim():null),{once:true})})
}

async function movePath(from,to){if(from===to)return;try{await api('/api/v1/move',{method:'POST',body:JSON.stringify({from,to,overwrite:false})});await load()}catch(err){message(err.message)}}
async function moveEntry(e){const from=join(state.path,e.name);const dest=await askText('Move to folder','/','Enter an existing folder path, for example /Photos');if(!dest)return;await movePath(from,join(dest.replace(/\/$/,''),e.name))}

async function renameEntry(e){const next=await askText('Rename item',e.name,'Use a name, not a path.');if(!next||next===e.name)return;if(next.includes('/')||next==='.'||next==='..'){message('Names cannot contain slashes.');return}await movePath(join(state.path,e.name),join(state.path,next.normalize('NFC')))}
async function deleteEntry(e){
	if(await confirmAction(`Delete ${e.name}?`,'This removes it from the NAS for everyone with access. ZFS snapshots are the recovery path.','Delete')){try{await api(`/api/v1/entry?path=${encodeURIComponent(join(state.path,e.name))}`,{method:'DELETE'});await load()}catch(err){message(err.message)}}
}
function confirmAction(title,text,label){$('#confirm-title').textContent=title;$('#confirm-text').textContent=text;$('#confirm-ok').textContent=label;const d=$('#confirm-dialog');d.returnValue='cancel';d.showModal();return new Promise(resolve=>d.addEventListener('close',()=>resolve(d.returnValue==='ok'),{once:true}))}
async function newFolder(){const name=await askText('New folder','untitled folder');if(!name)return;if(name.includes('/')){message('Folder names cannot contain slashes.');return}try{await api('/api/v1/mkdir',{method:'POST',body:JSON.stringify({path:join(state.path,name.normalize('NFC'))})});await load()}catch(err){message(err.message)}}

function getFavs(){try{return JSON.parse(localStorage.getItem('share-favourites')||'[]')}catch{return []}}
function setFavs(v){localStorage.setItem('share-favourites',JSON.stringify(v));renderFavourites()}
function renderFavourites(){const box=$('#favourites');box.replaceChildren();for(const p of getFavs()){const b=button('★ '+(p==='/'?'Share':p.split('/').pop()),()=>load(p,true));b.className='side';b.title=p;box.append(b)}}
function toggleFavourite(){let f=getFavs();f=f.includes(state.path)?f.filter(x=>x!==state.path):[...f,state.path];setFavs([...new Set(f)]);render()}

async function uploadFiles(files,destination=state.path){
	if(!files.length)return;$('#transfers').hidden=false;
	const queue=[...files].map(item=>item.file?transferJob(item.file,destination,item.relativePath):transferJob(item,destination,item.name));
	const workers=[worker(queue),worker(queue)];await Promise.all(workers);await load();
}
function transferJob(file,destination,relativePath){
	const controller=new AbortController(),item=document.createElement('div'),head=document.createElement('div'),name=document.createElement('strong'),cancel=button('Cancel',()=>{controller.abort();cancel.disabled=true;detail.textContent='Cancelling…'}),detail=document.createElement('small'),bar=document.createElement('div'),fill=document.createElement('i');
	item.className='transfer';head.className='transfer-head';name.className='transfer-name';name.textContent=relativePath;cancel.className='transfer-cancel';detail.textContent=`Waiting · ${fmtSize(file.size)}`;bar.className='bar';bar.append(fill);head.append(name,cancel);item.append(head,bar,detail);$('#transfer-list').prepend(item);
	return {file,destination,relativePath,controller,name,cancel,detail,fill};
}
async function worker(queue){while(queue.length){const job=queue.shift();if(!job.controller.signal.aborted)await uploadOne(job);else{job.detail.textContent='Cancelled';job.name.textContent=`× ${job.file.name}`;job.cancel.remove()}}}
async function uploadOne(job){
	const {file,destination,relativePath,controller,name,cancel,detail,fill}=job;state.uploads++;let uploadID=null;
	try{
		const target=join(destination,relativePath.normalize('NFC'));let overwrite=false,start;
		const folder=parent(target);if(folder!==destination)await api('/api/v1/mkdir',{method:'POST',signal:controller.signal,body:JSON.stringify({path:folder})});
    detail.textContent=`Starting · ${fmtSize(file.size)}`;
    try{start=await api('/api/v1/uploads',{method:'POST',signal:controller.signal,body:JSON.stringify({path:target,size:file.size,modified:new Date(file.lastModified).toISOString(),overwrite:false})})}
	catch(e){if(e.code!=='exists'||!await confirmAction('Replace existing file?',`${file.name} already exists in this folder.`,'Replace'))throw e;overwrite=true;start=await api('/api/v1/uploads',{method:'POST',signal:controller.signal,body:JSON.stringify({path:target,size:file.size,modified:new Date(file.lastModified).toISOString(),overwrite})})}
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
		name.textContent=`✓ ${relativePath}`;detail.textContent='Complete';cancel.remove();fill.style.width='100%';
  }catch(e){
    if(uploadID)await api(`/api/v1/uploads/${uploadID}`,{method:'DELETE'}).catch(()=>{});
		if(controller.signal.aborted){detail.textContent='Cancelled';name.textContent=`× ${relativePath}`}
    else{detail.textContent=`Failed: ${e.message}`;message(`${file.name}: ${e.message}`)}
    cancel.remove();
  }finally{state.uploads--}
}

async function filesFromDrop(dataTransfer){
	const out=[];
	const fallback=[...dataTransfer.files].map(file=>({file,relativePath:file.name}));
	const walk=async(entry,prefix)=>{
		if(entry.isFile){const file=await new Promise((resolve,reject)=>entry.file(resolve,reject));out.push({file,relativePath:prefix+file.name});return}
		if(entry.isDirectory){const reader=entry.createReader();for(;;){const children=await new Promise((resolve,reject)=>reader.readEntries(resolve,reject));if(!children.length)break;for(const child of children)await walk(child,prefix+entry.name+'/')}}
	};
	const items=[...dataTransfer.items].filter(item=>item.kind==='file');
	if(items.length && items.every(item=>typeof item.webkitGetAsEntry==='function')){
		for(const item of items){const entry=item.webkitGetAsEntry();if(entry)await walk(entry,'')}
		if(out.length)return out
	}
	return fallback;
}

async function showAdmin(){try{await refreshUsers();$('#admin-dialog').showModal()}catch(err){message(err.message)}}
async function refreshUsers(){const data=await api('/api/v1/admin/users');const box=$('#user-list');box.replaceChildren();for(const user of data.users){
	const card=document.createElement('article');card.className='user-card';const head=document.createElement('div');head.className='user-head';const title=document.createElement('strong');title.textContent=`${user.name}${user.admin?' · admin':''}`;head.append(title);
	const reset=button('Reset password',async()=>{const password=await askText(`New password for ${user.name}`,'','At least 12 characters. Existing sessions will be signed out.',true);if(!password)return;try{await api(`/api/v1/admin/users/${user.id}`,{method:'PUT',body:JSON.stringify({password})});message('Password updated.');await refreshUsers()}catch(err){message(err.message)}});head.append(reset);
	if(user.id!==state.user?.id){const del=button('Remove account',async()=>{if(!await confirmAction(`Remove ${user.name}?`,'Their access ends immediately. Files remain on the NAS.','Remove'))return;try{await api(`/api/v1/admin/users/${user.id}`,{method:'DELETE'});await refreshUsers()}catch(err){message(err.message)}});head.append(del)}
	card.append(head);const grants=document.createElement('div');grants.className='user-grants';if(!user.grants?.length){const empty=document.createElement('small');empty.textContent=user.admin?'Administrators can access every file.':'No files shared yet.';grants.append(empty)}
	for(const g of user.grants||[]){const line=document.createElement('div');line.className='grant';const label=document.createElement('span');label.textContent=`${g.path} · ${g.write?'read/write':'read only'}`;const toggle=button(g.write?'Make read only':'Allow edits',async()=>{try{await api(`/api/v1/admin/users/${user.id}`,{method:'PUT',body:JSON.stringify({grants:user.grants.map(x=>x.path===g.path?{...x,write:!x.write}:x)})});await refreshUsers()}catch(err){message(err.message)}});const remove=button('Revoke',async()=>{try{await api(`/api/v1/admin/users/${user.id}`,{method:'PUT',body:JSON.stringify({grants:user.grants.filter(x=>x.path!==g.path)})});await refreshUsers()}catch(err){message(err.message)}});line.append(label,toggle,remove);grants.append(line)}card.append(grants);box.append(card)} }

async function shareEntry(e){try{const data=await api('/api/v1/admin/users');const names=data.users.filter(u=>u.id!==state.user?.id).map(u=>u.name).join(', ');const name=await askText('Share with person','',`Account username. Available: ${names||'create an account first in Users'}`);if(!name)return;const user=data.users.find(u=>u.name.toLowerCase()===name.toLowerCase());if(!user){message('No matching account. Add the person in Users first.');return}const p=join(state.path,e.name);const grants=[...(user.grants||[]).filter(g=>g.path!==p),{path:p,write:false}];await api(`/api/v1/admin/users/${user.id}`,{method:'PUT',body:JSON.stringify({grants})});message(`${e.name} shared with ${user.name} as read only.`)}catch(err){message(err.message)}}

$('#user-form').onsubmit=async ev=>{ev.preventDefault();try{await api('/api/v1/admin/users',{method:'POST',body:JSON.stringify({username:$('#new-username').value.trim(),password:$('#new-password').value})});$('#user-form').reset();await refreshUsers();message('Account created. Share a file or folder to grant access.')}catch(err){message(err.message)}};
$('#account').onclick=async()=>{const current=await askText('Current password','','Enter your current password.',true);if(current===null)return;const next=await askText('Choose new password','','At least 12 characters. Other sessions will sign out.',true);if(!next)return;try{const data=await api('/api/v1/me/password',{method:'POST',body:JSON.stringify({current,next})});state.key=data.token;sessionStorage.setItem('share-token',data.token);message('Password changed.')}catch(err){message(err.message)}};
async function checkUpdates(silent=false){try{const [installed,release]=await Promise.all([fetch('/api/v1/version',{cache:'no-store'}).then(r=>r.json()),fetch('https://api.github.com/repos/palermostest25/Share/releases/latest',{headers:{Accept:'application/vnd.github+json'}}).then(r=>{if(!r.ok)throw new Error('GitHub releases are unavailable.');return r.json()})]);const current=installed.version.replace(/^v/,''),latest=release.tag_name.replace(/^v/,'');if(current===latest){if(!silent)message(`Share ${current} is current.`);return}const newest=latest.localeCompare(current,undefined,{numeric:true})>0;if(newest){if(await confirmAction(`Share ${latest} is available`,`This server is ${current}. Open the release for downloads and TrueNAS update instructions?`,'Open release'))window.open(release.html_url,'_blank','noopener')}else if(!silent)message(`Share ${current} is newer than the latest published release.`)}catch(err){if(!silent)message(err.message)}}
function backgroundUpdateCheck(){if(!state.user?.admin)return;const last=Number(localStorage.getItem('share-update-checked')||0);if(Date.now()-last<86400000)return;localStorage.setItem('share-update-checked',String(Date.now()));setTimeout(()=>checkUpdates(true),1500)}
$('#updates').onclick=()=>checkUpdates();
$('#admin').onclick=showAdmin;$('#admin-close').onclick=()=>$('#admin-dialog').close();

$('#login-form').addEventListener('submit',async e=>{e.preventDefault();try{
	const body=state.needsSetup?{accessKey:$('#access-key').value,username:$('#username').value.trim(),password:$('#password').value}:{username:$('#username').value.trim(),password:$('#password').value};
	const res=await fetch(state.needsSetup?'/api/v1/setup':'/api/v1/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body),cache:'no-store'});
	const data=await res.json();if(!res.ok)throw new Error(data.message||'Sign-in failed');state.key=data.token;state.user=data.user;state.needsSetup=false;sessionStorage.setItem('share-token',state.key);$('#password').value='';$('#access-key').value='';$('#login-dialog').close();$('#login-error').hidden=true;await load('/');backgroundUpdateCheck();
}catch(err){$('#login-error').textContent=err.message;$('#login-error').hidden=false}});
$('#back').onclick=()=>{const p=state.history.pop();if(p)load(p)};$('#up').onclick=()=>load(parent(state.path),true);$('#refresh').onclick=()=>load();$('#new-folder').onclick=newFolder;$('#upload-input').onchange=e=>{uploadFiles(e.target.files);e.target.value=''};$('#logout').onclick=()=>lock();$('#filter').oninput=render;$('#favourite-current').onclick=toggleFavourite;$('#all-files').onclick=()=>load('/',true);
$('#mobile-files').onclick=()=>{document.querySelector('aside').classList.remove('mobile-open');load('/',true)};
$('#mobile-favourites').onclick=()=>document.querySelector('aside').classList.toggle('mobile-open');
$('#mobile-transfers').onclick=()=>{$('#context-menu').hidden=true;if($('#transfers').hidden)message('No transfers yet.');else $('#transfers').scrollIntoView({behavior:'smooth',block:'end'})};
$('#mobile-more').onclick=()=>$('#mobile-actions-dialog').showModal();
$('#mobile-actions-close').onclick=()=>$('#mobile-actions-dialog').close();
for(const [mobile,desktop] of [['mobile-new-folder','new-folder'],['mobile-favourite-current','favourite-current'],['mobile-account','account'],['mobile-admin','admin'],['mobile-updates','updates'],['mobile-logout','logout']]){
    $(`#${mobile}`).onclick=()=>{$('#mobile-actions-dialog').close();$(`#${desktop}`).click()};
}
$('#mobile-upload-label').onkeydown=event=>{if((event.key==='Enter'||event.key===' ')&&!$('#upload-input').disabled){event.preventDefault();$('#upload-input').click()}};
document.querySelectorAll('th[data-sort]').forEach(th=>th.onclick=()=>{const s=th.dataset.sort;if(state.sort===s)state.ascending=!state.ascending;else{state.sort=s;state.ascending=true}render()});
$('#media-close').onclick=()=>$('#media-dialog').close();$('#media-dialog').addEventListener('close',()=>{for(const el of [$('#video'),$('#audio')]){el.pause();el.removeAttribute('src');el.load()}});
const dz=$('#drop-zone');
document.addEventListener('dragover',e=>{e.preventDefault();if([...e.dataTransfer.types].includes('Files')){$('#drop-hint').hidden=false;dz.classList.add('dragging')}});
document.addEventListener('dragleave',e=>{if(!e.relatedTarget){$('#drop-hint').hidden=true;dz.classList.remove('dragging')}});
document.addEventListener('drop',async e=>{e.preventDefault();$('#drop-hint').hidden=true;dz.classList.remove('dragging');if(e.dataTransfer.getData('application/x-share-entry'))return;if(e.dataTransfer.files.length){if(canWrite(state.path))uploadFiles(await filesFromDrop(e.dataTransfer));else message('You do not have write access to this folder.')}});
window.addEventListener('focus',()=>state.key&&load());setInterval(()=>{if(!document.hidden&&state.key)load()},30000);
(async()=>{try{const status=await fetch('/api/v1/setup/status',{cache:'no-store'}).then(r=>r.json());state.needsSetup=!!status.needsSetup;$('#bootstrap-field').hidden=!state.needsSetup;$('#login-help').textContent=state.needsSetup?'Create the first administrator account with the bootstrap key from your Compose file.':'Sign in with your Share account.';$('#login-submit').textContent=state.needsSetup?'Create administrator':'Sign in';if(state.key){try{state.user=await api('/api/v1/me');await load('/');backgroundUpdateCheck();return}catch{}}lock()}catch{lock('Share is unreachable. Check the server connection and retry.')}})();
