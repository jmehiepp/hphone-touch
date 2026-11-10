-- Original compatibility layer. Native failures are propagated, never fabricated.
local native = _hp
local function call(kind,op,args)
  local r=native(kind,op,args or {})
  if r.error and r.error~='' then error(r.error,3) end
  if r.ok==false then error('Native operation failed: '..op,3) end
  return r
end
local function input(op,args) return call('input',op,args) end
local function visual(op,args) return call('visual',op,args) end
local function service(op,args)
  local r=native('service',op,args or {})
  if not r.ok then return nil,r.error end
  return r.value,r
end
function jsonEncode(v,pretty) return _json('encode',v,pretty) end
function jsonDecode(s) return _json('decode',s) end
function base64Encode(s) return _b64(true,s) end
function base64Decode(s) return _b64(false,s) end
function usleep(n) return sleep(n/1000000) end
function stop() error('Stopped by script',0) end
exit=stop
function rootDir() return _HP_ROOT end
function botPath() return _HP_ROOT..'/'.._HP_NAME end
function currentDir() return botPath():match('^(.*)/') end
local function relative(path)
  path=path or ''
  if path:sub(1,1)=='/' then return path end
  local dir=_HP_NAME:match('^(.*)/')
  return dir and (dir..'/'..path) or path
end
package.path=currentDir()..'/?.lua;'..rootDir()..'/?.lua;'..rootDir()..'/?/init.lua'
local function file(action,path,value)
  local args={action=action,path=relative(path)}
  if value~=nil then args.base64=base64Encode(value) end
  local r=native('fs',action,args)
  if not r.ok then return nil,r.error end
  return r
end
function readFile(path) local r,e=file('read',path);if not r then return nil,e end;return base64Decode(r.base64) end
function writeFile(path,content) local r,e=file('write',path,content);return r and true or nil,e end
function appendFile(path,content) local r,e=file('append',path,content);return r and true or nil,e end
function removeFirstLine(path) local r,e=file('removeFirstLine',path);return r and r.line or nil,e end
function fileExists(path) local r=file('exists',path);return r and r.exists or false end
function deleteFile(path) local r=file('delete',path);return r and true or false end
function listDir(path) local r,e=file('list',path);if not r then return nil,e end;return r.entries end
function readLines(path)
  local text,e=readFile(path);if not text then return nil,e end
  local lines={};for line in (text..'\n'):gmatch('(.-)\n') do lines[#lines+1]=line:gsub('\r$','') end
  if text:sub(-1)=='\n' or text=='' then table.remove(lines) end;return lines
end
function string.startswith(s,p) return s:sub(1,#p)==p end
function string.endswith(s,p) return p=='' or s:sub(-#p)==p end
function table.tostring(value)
  local seen={}
  local function dump(v,depth)
    if type(v)~='table' then return type(v)=='string' and string.format('%q',v) or tostring(v) end
    if seen[v] then return '<cycle>' end;if depth>16 then return '<depth>' end;seen[v]=true
    local parts={};for k,x in pairs(v) do parts[#parts+1]='['..dump(k,depth+1)..']='..dump(x,depth+1) end
    seen[v]=nil;return '{'..table.concat(parts,', ')..'}'
  end
  return dump(value,0)
end
table.toString=table.tostring
KEY_TYPE={HOME_BUTTON='home',POWER_BUTTON='power',VOLUME_UP_BUTTON='volumeUp',VOLUME_DOWN_BUTTON='volumeDown'}
CONTROLLER_TYPE={LABEL='LABEL',INPUT='INPUT',TEXTVIEW='TEXTVIEW',PICKER='PICKER',SWITCH='SWITCH',BUTTON='BUTTON',REMEMBER='REMEMBER'}
ORIENTATION_TYPE={UNKNOWN=0,PORTRAIT=1,PORTRAIT_UPSIDE_DOWN=2,LANDSCAPE_LEFT=3,LANDSCAPE_RIGHT=4}
function getVersion() return '0.2.0' end
function getOrientation() return ORIENTATION_TYPE.PORTRAIT end
function tap(x,y,count,interval) return input('tap',{x=x,y=y,count=count,interval_us=interval}).dispatched end
function doubleTap(x,y,gap) return input('doubleTap',{x=x,y=y,gap_ms=gap}).dispatched end
function longPress(x,y,ms) return input('longPress',{x=x,y=y,ms=ms}).dispatched end
for _,name in ipairs({'touchDown','touchMove','touchUp'}) do _G[name]=function(id,x,y) return input(name,{id=id,x=x,y=y}).dispatched end end
function swipe(x1,y1,x2,y2,ms,steps,id) return input('swipe',{x1=x1,y1=y1,x2=x2,y2=y2,ms=ms,steps=steps,id=id}).dispatched end
function swipeHold(x1,y1,x2,y2,hold,move,finish) return input('swipeHold',{x1=x1,y1=y1,x2=x2,y2=y2,hold_ms=hold,move_ms=move,end_hold_ms=finish}).dispatched end
function swipePath(points,ms,id) return input('swipePath',{points=points,ms=ms,id=id}).dispatched end
function pinch(cx,cy,startDist,endDist,ms) return input('pinch',{cx=cx,cy=cy,startDist=startDist,endDist=endDist,ms=ms}).dispatched end
function getScreenResolution() local r=visual('resolution');return r.width,r.height end
function getScreenScale() return visual('resolution').scale end
function getScreenSize() local r=visual('resolution');return r.width/r.scale,r.height/r.scale end
function scroll(direction,distance,ms,x,y)
  local w,h=getScreenResolution();x=x or w/2;y=y or h/2;distance=distance or h*.4
  local vectors={up={0,-1},down={0,1},left={-1,0},right={1,0}};local d=assert(vectors[direction],'Unknown scroll direction')
  return swipe(x,y,math.max(0,math.min(w-1,x+d[1]*distance)),math.max(0,math.min(h-1,y+d[2]*distance)),ms or 600)
end
for _,name in ipairs({'keyDown','keyUp','keyPress'}) do _G[name]=function(k) return input(name,{key=k}).dispatched end end
key=keyPress
function inputText(text,delay) return input('inputText',{text=text,delay_us=delay}).dispatched end
function intToRgb(c) c=math.tointeger(c);return (c>>16)&255,(c>>8)&255,c&255 end
function rgbToInt(r,g,b) return (math.tointeger(r)<<16)|(math.tointeger(g)<<8)|math.tointeger(b) end
function getColor(x,y) return visual('getColor',{x=x,y=y}).color end
function getColors(points) return visual('getColors',{points=points}).colors end
local colorTolerance=0
function setColorTolerance(n) assert(math.type(n)=='integer' and n>=0 and n<=255,'Tolerance must be0..255');colorTolerance=n end
function keepScreen(on) return visual('keepScreen',{enabled=on}).enabled end
function findColor(color,count,region,debug,rtl,btt,tolerance) return visual('findColor',{color=color,count=count,region=region,rightToLeft=rtl,bottomToTop=btt,tolerance=tolerance or colorTolerance}).points end
function findColors(colors,count,region,debug,rtl,btt,tolerance)
  local pattern={};for i,p in ipairs(colors) do pattern[i]={color=p[1] or p.color,dx=p.dx or (p.any and p[1]) or p[2] or 0,dy=p.dy or (p.any and p[2]) or p[3] or 0,tolerance=p.tolerance or p[4],any=p.any,['not']=p['not']} end
  return visual('findColors',{colors=pattern,count=count,region=region,rightToLeft=rtl,bottomToTop=btt,tolerance=tolerance or colorTolerance}).points
end
function isColor(x,y,color,tolerance) local r,g,b=intToRgb(getColor(x,y));local R,G,B=intToRgb(color);local t=tolerance or colorTolerance;return math.abs(r-R)<=t and math.abs(g-G)<=t and math.abs(b-B)<=t end
compareColor=isColor
function matchColors(colors,tolerance) return visual('matchColors',{colors=colors,tolerance=tolerance or colorTolerance}).match end
function getColorCount(color,region,tolerance) return visual('colorCount',{color=color,region=region,tolerance=tolerance or colorTolerance}).count end
function findColorList(colors,count,region,tolerance) local out={};for _,color in ipairs(colors) do for _,p in ipairs(findColor(color,count,region,nil,nil,nil,tolerance)) do out[#out+1]={p[1],p[2],color} end end;return out end
function findMultiColor(color,spec,similarity,region,count,rtl,btt)
  local pattern={{color,0,0}};local tol=math.floor((100-(similarity or 90))*255/100)
  for part in spec:gmatch('[^,]+') do
    local dx,dy,v=part:match('^%s*([%-%.%d]+)|([%-%.%d]+)|(.+)%s*$');assert(dx,'Invalid multicolor specification')
    local neg=v:sub(1,1)=='!';if neg then v=v:sub(2) end
    local c,t=v:match('^(.-)%-(%d+)$');v=c or v
    pattern[#pattern+1]={color=v~='*' and assert(tonumber(v),'Invalid color') or nil,dx=tonumber(dx),dy=tonumber(dy),any=v=='*',['not']=neg,tolerance=tonumber(t)}
  end
  local pts=findColors(pattern,count or 1,region,nil,rtl,btt,tol);if count and count>1 then return pts end
  return pts[1] and pts[1][1] or -1,pts[1] and pts[1][2] or -1
end
local function center(points,ix,iy)
  local minx,miny,maxx,maxy=math.huge,math.huge,-math.huge,-math.huge
  for _,p in ipairs(points) do minx=math.min(minx,p[ix]);miny=math.min(miny,p[iy]);maxx=math.max(maxx,p[ix]);maxy=math.max(maxy,p[iy]) end
  if #points==0 then return 0,0 end;return (minx+maxx)/2,(miny+maxy)/2
end
function centerOffsetOfPoints(p) return center(p,1,2) end
function centerOffsetOfPixels(p) return center(p,2,3) end
function screenshot(path,region)
  path=path or ('screenshot-'..os.time()..'.png');local r=visual('screenshot',{region=region})
  local saved=call('fs','write',{action='write',path=relative(path),base64=r.pngBase64});return saved.path
end
function findImage(options)
  if type(options)=='string' then options={image=options} end
  local a={};for k,v in pairs(options) do a[k]=v end;a.image=relative(a.image)
  return visual('findImage',a).matches
end
function findImageTap(image,count,threshold,region,ox,oy)
  local matches=findImage({image=image,count=count or 1,threshold=threshold,region=region})
  for _,m in ipairs(matches) do tap(m.centerX+(ox or 0),m.centerY+(oy or 0)) end;return matches
end
tapImage=findImageTap
local function waitFor(fn,timeout,interval)
  timeout=timeout or 10;interval=interval or .2
  assert(timeout>=0 and timeout<=86400 and interval>=0,'Invalid wait duration')
  local deadline=millis()+timeout*1000
  repeat local result=fn();if result then return result end;if millis()>=deadline then return nil end;sleep(math.max(.01,interval)) until false
end
function waitImage(image,timeout,threshold,region,interval) return waitFor(function() return findImage({image=image,count=1,threshold=threshold,region=region})[1] end,timeout,interval) end
function waitImageTap(image,timeout,threshold,region,interval,ox,oy) local m=waitImage(image,timeout,threshold,region,interval);if m then local x,y=m.centerX+(ox or 0),m.centerY+(oy or 0);tap(x,y);return x,y end end
local function tapPoints(points,ox,oy) for _,p in ipairs(points) do tap(p[1]+(ox or 0),p[2]+(oy or 0)) end;return points end
function findColorTap(color,count,region) return tapPoints(findColor(color,count or 1,region)) end
function findColorsTap(colors,count,region) return tapPoints(findColors(colors,count or 1,region)) end
function tapColors(colors,region,tolerance,index,ox,oy,timeout,interval)
  local p=waitFor(function() return findColors(colors,index or 1,region,nil,nil,nil,tolerance)[index or 1] end,timeout or 0,interval)
  if p then local x,y=p[1]+(ox or 0),p[2]+(oy or 0);tap(x,y);return x,y end
end
function tapColor(color,...) return tapColors({{color,0,0}},...) end
function tapMultiColor(color,spec,similarity,region,ox,oy,timeout,interval)
  local p=waitFor(function() local x,y=findMultiColor(color,spec,similarity,region);if x>=0 then return {x,y} end end,timeout or 0,interval)
  if p then local x,y=p[1]+(ox or 0),p[2]+(oy or 0);tap(x,y);return x,y end
end
function waitColor(color,x,y,timeout,interval) return waitFor(function() return isColor(x,y,color) end,(timeout or 10000000)/1e6,(interval or 100000)/1e6)~=nil end
function keep(fn,interval,timeout) return waitFor(fn,(timeout and timeout>0) and timeout/1e6 or 86400,(interval or 100000)/1e6)~=nil end
function keepFindingColor(color,count,region,fn,interval,timeout) return keep(function() local p=findColor(color,count,region);if #p>0 then return fn(p) end end,interval,timeout) end
function keepFindingColors(colors,count,region,fn,interval,timeout) return keep(function() local p=findColors(colors,count,region);if #p>0 then return fn(p) end end,interval,timeout) end
function keepFindingColorTap(color,count,region,interval,timeout) return keepFindingColor(color,count,region,function(p) tapPoints(p) end,interval,timeout) end
function keepFindingColorsTap(colors,count,region,interval,timeout) return keepFindingColors(colors,count,region,function(p) tapPoints(p) end,interval,timeout) end
local ocrEngine='auto'
function setOcrEngine(engine) assert(engine=='auto' or engine=='vision' or engine=='tesseract','Unknown OCR engine');ocrEngine=engine end
function ocr(options)
  options=options or {};if options[1] then options={region=options} end
  local args={engine=ocrEngine};for k,v in pairs(options) do args[k]=v end
  return call('ocr','recognize',args).items
end
function getText(options) local text={};for _,p in ipairs(ocr(options)) do text[#text+1]=p.text end;return table.concat(text,'\n') end
function findText(text,options,exact)
  local out={};text=text:lower();for _,p in ipairs(ocr(options)) do local t=p.text:lower();if (exact and t==text) or (not exact and t:find(text,1,true)) then out[#out+1]=p end end;return out
end
function waitText(text,options,timeout,interval,exact) return waitFor(function() return findText(text,options,exact)[1] end,timeout,interval or .5) end
function tapText(text,options,timeout,interval,exact) local p=waitText(text,options,timeout or 0,interval,exact);if p then tap(p.centerX,p.centerY);return p.centerX,p.centerY end end
function dumpColorsOfScreen(path,region,rgb,coords)
  local w,h=getScreenResolution();region=region or {0,0,w,h};assert(region[3]*region[4]<=10000,'Dump limit 10000 pixels')
  keepScreen(true);local ok,result=pcall(function() local lines={};for y=region[2],region[2]+region[4]-1 do for x=region[1],region[1]+region[3]-1 do local c=getColor(x,y);local s=string.format('0x%06X',c);if rgb then local r,g,b=intToRgb(c);s=string.format('%d,%d,%d',r,g,b) end;lines[#lines+1]=(coords and (x..','..y..':') or '')..s end end;return assert(writeFile(path,table.concat(lines,'\n'))) end);keepScreen(false);if not ok then error(result) end;return result
end
for _,op in ipairs({'appRun','appKill','appState','appIsActive','appInfo','memoryUsageOfApp'}) do _G[op]=function(bundle) return service(op,{bundleId=bundle}) end end
function appActivate(bundle,timeout) return service('appActivate',{bundleId=bundle,timeout=timeout}) end
for _,op in ipairs({'frontMostAppId','runningApps','isScreenLocked','getSN','getLocalIP','captureDebugInfo','memoryUsageOfTotal','clipText','vibrate','listInstalledApps','stopAudio','pauseAudio','resumeAudio','isKeepingAutoTouchAwake'}) do _G[op]=function() return service(op) end end
function openURL(url) return service('openURL',{url=url}) end
function copyText(text) return service('copyText',{text=text}) end
function keepAutoTouchAwake(on) return service('keepAutoTouchAwake',{enabled=on}) end
function playAudio(path,times) if path:sub(1,1)~='/' then path=currentDir()..'/'..path end;return service('playAudio',{path=path,times=times}) end
function execute(command) local r,e=service('execute',{command=command});if not r then return nil,e end;if r.timedOut or r.truncated then return nil,'Command timed out or output limit reached' end;return r.output,r.exitCode end
function backupApp(bundle,name) local value,r=service('backupApp',{bundleId=bundle,name=name});return value or {ok=false,error=r} end
function restoreApp(bundle,name) local value,r=service('restoreApp',{bundleId=bundle,name=name,confirmBundle=bundle});if not value then return {ok=false,error=r} end;value.recoveryBackup=r.recoveryBackup;return value end
function wipeApp(bundle) local value,r=service('wipeApp',{bundleId=bundle,confirmBundle=bundle});if not value then return {ok=false,error=r} end;value.recoveryBackup=r.recoveryBackup;return value end
function deleteBackup(bundle,name) local value,e=service('deleteBackup',{bundleId=bundle,name=name});return {ok=value==true,error=e and type(e)=='string' and e or nil} end
function listBackups(bundle) return service('listBackups',{bundleId=bundle}) end
function runScript(path) local r=native('jobs','run',{name=relative(path)});return r.id,r.error end
function stopScript(id) return call('jobs','stop',{id=id}).count end
function stopAllScripts() call('jobs','stop');stop() end
function runningScripts() return call('jobs','list').jobs end
function isScriptRunning(path) path=relative(path);for _,j in ipairs(runningScripts()) do if j.name==path or j.path==path then return true end end;return false end
function setTimer(path,fire,rep,interval) return call('schedule','set',{action='set',name=relative(path),fireTime=fire,['repeat']=rep,interval=interval}).ok end
function removeTimer(path) return call('schedule','remove',{action='remove',name=relative(path)}).ok end
function setAutoLaunch(path,on) return call('schedule','auto',{action='auto',name=relative(path),enabled=on}).ok end
function listAutoLaunch() return call('schedule','listAuto',{action='listAuto'}).paths end
function toast(message,seconds,position) return call('ui','show',{type='toast',message=tostring(message),seconds=seconds,position=position,owner=_HP_ID}).id end
function alert(message,title) return call('ui','show',{type='alert',message=tostring(message),title=title,owner=_HP_ID}).id end
function dialog(controls,orientations)
  local r=call('ui','show',{type='dialog',controls=controls,owner=_HP_ID})
  for i,value in ipairs(r.controls or {}) do if controls[i] then controls[i].value=value.value end end;return r.button
end
function clearDialogValues() return true end -- This version does not persist input values.
local function http(method,url,body,opts)
  opts=opts or {};local args={method=method,url=url};for k,v in pairs(opts) do args[k]=v end
  if type(body)=='table' then args.json=body elseif body~=nil then args.body=body end
  local r=native('http','request',args);if r.bodyBase64 then r.body=assert(base64Decode(r.bodyBase64));r.bodyBase64=nil end;return r
end
function httpGet(url,opts) return http('GET',url,nil,opts) end
function httpPost(url,body,opts) return http('POST',url,body,opts) end
function httpRequest(opts) return http(opts.method or 'GET',opts.url,nil,opts) end
for _,op in ipairs({'getCookies','getCookieHeader','getCookiesText','getCookiesJSON','getSafariCookies'}) do _G[op]=function(opts) if type(opts)=='string' then opts={domain=opts} end;return service(op,opts or {}) end end
function safariCookiesPath() return service('safariCookiesPath') end
function importCookies(cookies,opts) opts=opts or {};opts.cookies=cookies;return service('importCookies',opts) end
setCookies=importCookies
function deleteCookies(domain,opts) opts=opts or {};opts.domain=domain;return service('deleteCookies',opts) end
clearCookies=deleteCookies
function restoreCookies(path) return service('restoreCookies',{file=path}) end
for _,op in ipairs({'airplaneMode','wifi','cellularData'}) do _G[op]=function(on) return service(op,{enabled=on}) end end
wifiEnabled=wifi;setWifi=wifi;setCellularData=cellularData
function getRadios() local a=airplaneMode();local w=wifi();local c=cellularData();return a,w,c end
function getProxy() return service('getProxy') end
function setProxy(proxy) return service('setProxy',{proxy=proxy}) end
function clearProxy() return service('clearProxy') end
function fakeLocation(lat,lng,altitude) return service('fakeLocation',{latitude=lat,longitude=lng,altitude=altitude}) end
function clearLocation() return service('clearLocation') end
function fakeLocationByIP(ip) return nil,'Geolocation provider must be configured explicitly; no external IP service is called automatically' end
for _,name in ipairs({'lockScreen','unlockScreen','respring','saveToSystemAlbum','clearSystemAlbum','isSafeMode','exitSafeMode','setAutoExitSafeMode'}) do _G[name]=function(...) return nil,name..' requires a separately verified device helper' end end
