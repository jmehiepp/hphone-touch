'use strict';
const $=id=>document.getElementById(id);
let token=window.HPHONE_TOKEN||sessionStorage.getItem('hphoneToken')||'',lastLog=0,previewURL='',polling=false;
let noticeTimer;
function notice(message){$('notice').textContent=message;$('notice').hidden=false;clearTimeout(noticeTimer);noticeTimer=setTimeout(()=>$('notice').hidden=true,6000);}
async function api(path,body){
  const response=await fetch('/api/'+path,{method:body===undefined?'GET':'POST',headers:{'X-HPhone-Token':token,...(body===undefined?{}:{'Content-Type':'application/json'})},body:body===undefined?undefined:JSON.stringify(body),cache:'no-store'});
  if(response.status===401){$('connect').hidden=false;throw new Error('Cần token thiết bị');}
  if(!response.ok){let info;try{info=await response.json();}catch{}throw new Error(info?.error||'HTTP '+response.status);}
  return response.headers.get('Content-Type')?.includes('image/')?response.blob():response.json();
}
function action(id,fn){$(id).addEventListener('click',()=>Promise.resolve().then(fn).catch(e=>notice(e.message)));}
async function files(selected){const data=await api('files');$('files').replaceChildren(...data.files.map(name=>{const option=document.createElement('option');option.value=name;option.textContent=name;return option;}));if(selected)$('files').value=selected;}
async function load(){if(!$('files').value)return;$('name').value=$('files').value;$('code').value=(await api('file',{action:'read',name:$('files').value})).content;}
async function save(){const name=$('name').value.trim();if(!name.endsWith('.lua'))throw new Error('Tên script cần kết thúc bằng .lua');await api('file',{action:'save',name,content:$('code').value});await files(name);return name;}
async function screen(){const blob=await api('screen');if(previewURL)URL.revokeObjectURL(previewURL);previewURL=URL.createObjectURL(blob);$('preview').src=previewURL;$('preview').hidden=false;}
async function poll(){if(polling)return;polling=true;try{const data=await api('status');$('connect').hidden=true;$('status').textContent=data.running?'● Đang chạy script':'● Sẵn sàng';$('run').disabled=data.running;$('stop').disabled=!data.running;$('capabilities').textContent=JSON.stringify(data.capabilities,null,2);if(data.logs.length&&data.logs.at(-1).id<lastLog)lastLog=0;for(const row of data.logs){if(row.id>lastLog){$('logs').textContent+=row.text+'\n';lastLog=row.id;}}if($('logs').textContent.length>100000)$('logs').textContent=$('logs').textContent.slice(-80000);$('logs').scrollTop=$('logs').scrollHeight;}catch(e){$('status').textContent=e.message;}finally{polling=false;}}
action('login',async()=>{token=$('token').value.trim();sessionStorage.setItem('hphoneToken',token);await poll();await files();await load();});
action('new',()=>{$('files').selectedIndex=-1;$('name').value='new-script.lua';$('code').value="print('HPhone Touch')\n";$('code').focus();});
action('save',async()=>{await save();notice('Đã lưu script');});
action('delete',async()=>{const name=$('name').value;if(!confirm('Xóa '+name+'?'))return;await api('file',{action:'delete',name});await files();await load();});
action('run',async()=>{const name=await save();await api('run',{name});await poll();});
action('stop',async()=>{await api('stop',{});notice('Đã gửi yêu cầu dừng');});
action('screen',screen);
action('ocr',async()=>{$('ocrResult').textContent='Đang nhận dạng…';try{const data=await api('ocr',{});$('ocrResult').textContent=data.items.map(row=>row.text).join('\n')||'Không tìm thấy chữ';}catch(e){$('ocrResult').textContent=e.message;throw e;}});
action('clear',()=>{$('logs').textContent='';});
$('files').addEventListener('change',()=>load().catch(e=>notice(e.message)));
document.querySelectorAll('[data-key]').forEach(button=>button.addEventListener('click',()=>api('key',{key:button.dataset.key}).then(()=>notice('Đã gửi phím; kiểm tra trên iPhone')).catch(e=>notice(e.message))));
$('preview').addEventListener('click',async event=>{const image=$('preview'),rect=image.getBoundingClientRect();const x=Math.min(image.naturalWidth-1,Math.floor((event.clientX-rect.left)*image.naturalWidth/rect.width)),y=Math.min(image.naturalHeight-1,Math.floor((event.clientY-rect.top)*image.naturalHeight/rect.height));try{await api('tap',{x,y});notice(`Đã gửi chạm ${x}, ${y}; kiểm tra trên iPhone`);}catch(e){notice(e.message);}});
$('code').addEventListener('keydown',event=>{if(event.key==='Tab'){event.preventDefault();const area=event.target,start=area.selectionStart,end=area.selectionEnd;area.setRangeText('  ',start,end,'end');}});
poll().then(()=>files()).then(load).catch(()=>{});setInterval(poll,1500);
