'use strict';
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const assert=require('node:assert/strict');

const html=fs.readFileSync(path.resolve(__dirname,'../../module/webroot/index.html'),'utf8');
const script=html.match(/<script>([\s\S]*?)<\/script>/i);
assert(script,'WebUI JS missing');
const report=[
 'device=compatible',
 'wcg_next=on',
 'wcg_property=true',
 'expert_next=off',
 'hfr_next=off',
 'metamodule=meta-overlayfs',
 'expert_runtime=false',
 'hfr_runtime=false',
 'panel=mdss_dsi_p17_41_02_0a_amoled_dsc_vid',
 'sf_wcg=1',
 'p3_available=yes',
 'active_color=ColorMode::SRGB (7)',
 'boot_log_start',
 'WCG_ONLY: experimental flags disabled',
 'WCG_PROPERTY_APPLIED: P3 gamut accuracy not validated',
 'boot_log_end',
 'hfr_ui_result=not_verified',
 'expert_ui_result=not_verified'
].join('\n');

function fakeNode(){
  return {
    children:[],textContent:'',className:'',dataset:{},events:{},
    append(...children){this.children.push(...children);},
    replaceChildren(...children){this.children=children;},
    addEventListener(event,handler){this.events[event]=handler;}
  };
}
async function spin(){
  // ksu WebUI posts callbacks asynchronously after shell commands finish.
  for(let i=0;i<8;i++)await new Promise(resolve=>setTimeout(resolve,5));
}
function harness(statusResult=report){
  const ids={};
  for(const key of ['#status','#bootlog','#msg','#refresh'])ids[key]=fakeNode();
  const buttons=[fakeNode(),fakeNode()];
  buttons[0].dataset={feature:'expert',value:'on'};
  buttons[1].dataset={feature:'hfr',value:'on'};
  const document={
    querySelector(key){return ids[key];},
    querySelectorAll(query){return query==='[data-feature]'?buttons:[];},
    createElement:fakeNode
  };
  const commands=[];
  const window={};
  window.ksu={
    exec(command,callbackName){
      // Mock the *actual* KernelSU-Next API, including the problematic
      // one-arg sync fastCmd returning just the final stdout line.
      if(arguments.length===1)return statusResult.trim().split('\n').at(-1);
      assert.equal(arguments.length,2,'must use callback API');
      assert.match(callbackName,/^window\.__kcsExec\d+$/);
      commands.push(command);
      setTimeout(()=>{
        const callback=window[callbackName.slice('window.'.length)];
        assert.equal(typeof callback,'function','registered callback not found');
        if(command.endsWith('control.sh status')){
          callback(0,statusResult,'');
        }else if(command.endsWith('control.sh set expert on')){
          callback(0,'OK: expert=on (effective after next reboot)','');
        }else if(command.endsWith('control.sh set hfr on')){
          callback(0,'OK: hfr=on (effective after next reboot)','');
        }else if(command.includes('control.sh set')){
          callback(5,'','BLOCKED: test simulated failure');
        }else {
          callback(2,'','Unknown command');
        }
      },1);
    }
  };
  vm.runInNewContext(script[1],{document,window,Promise,setTimeout,clearTimeout,confirm:()=>true});
  return {document,window,ids,buttons,commands};
}
async function main(){
  const h=harness();
  await spin();
  const labels=h.ids['#status'].children.map(x=>x.children.map(y=>y.textContent));
  const lookup=new Map(labels);
  assert.equal(lookup.get('Perangkat/ROM'),'compatible');
  assert.equal(lookup.get('Properti WCG aktif'),'true');
  assert.equal(lookup.get('Display P3 tersedia'),'yes');
  assert.equal(lookup.get('Mode warna aktif'),'ColorMode::SRGB (7)');
  assert.equal(lookup.get('Expert flag runtime'),'false');
  assert.equal(lookup.get('HFR flag runtime'),'false');
  assert.equal(lookup.get('Expert UI berfungsi'),'not_verified');
  assert.match(h.ids['#bootlog'].textContent,/WCG_PROPERTY_APPLIED/);
  assert(h.commands.every(command=>command.startsWith('/system/bin/sh ')));
  // Toggle preserves stdout and triggers a full status refresh.
  await h.buttons[0].events.click();
  await spin();
  assert.match(h.ids['#msg'].textContent,/OK: expert=on/);
  await h.buttons[1].events.click();
  await spin();
  assert.match(h.ids['#msg'].textContent,/OK: hfr=on/);
  assert(h.commands.filter(c=>c.endsWith('control.sh status')).length>=3);
  // Broken partial stdout must raise an explicit error rather than a
  // plausible-looking status table full of 'Tidak tersedia'.
  const bad=harness('expert_ui_result=not_verified');
  await spin();
  assert.match(bad.ids['#status'].textContent,/Output status tidak lengkap/);
  assert.equal(bad.ids['#status'].children.length,0);
  console.log('PASS: KernelSU-Next callback bridge full stdout, toggles, and malformed response');
}
main().catch(e=>{console.error(e);process.exitCode=1});
