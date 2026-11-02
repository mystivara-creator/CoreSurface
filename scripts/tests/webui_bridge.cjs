'use strict';
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const assert=require('node:assert/strict');
const root=path.resolve(__dirname,'../..');
const html=fs.readFileSync(path.join(root,'module/webroot/index.html'),'utf8');
const script=html.match(/<script>([\s\S]*?)<\/script>/i);
assert(script, 'WebUI JS not found');
const report=[
 'device=compatible','wcg_next=on','wcg_property=true','sf_wcg=1',
 'p3_available=yes','active_color=ColorMode::SRGB (7)',
 'panel=mdss_dsi_p17_41_02_0a_amoled_dsc_vid',
 'expert_next=off','hfr_next=off','metamodule=missing',
 'boot_log_start','WCG_PROPERTY_APPLIED: P3 not calibrated','boot_log_end'
].join('\n');

async function test(mode){
 const nodes = {};
 function element(){return {children:[],textContent:'',className:'',append(...c){this.children.push(...c)},replaceChildren(...c){this.children=c},addEventListener(){}};}
 for(const id of ['#status','#bootlog','#msg','#refresh'])nodes[id]=element();
 const fakeDocument={
   querySelector(s){return nodes[s]},
   querySelectorAll(){return []},
   createElement:element
 };
 const exec=cmd=>{
   assert(cmd.endsWith('control.sh status'), 'unexpected shell command');
   if(mode==='string')return report;
   if(mode==='object')return {stdout:report,errno:0};
   if(mode==='promise')return Promise.resolve({stdout:report,errno:0});
   throw Error('unsupported mode');
 };
 vm.runInNewContext(script[1],{document:fakeDocument,window:{ksu:{exec}},Promise,confirm:()=>true});
 await new Promise(resolve=>setTimeout(resolve,0));
 const values=nodes['#status'].children.map(row=>row.children[1].textContent);
 assert(values.includes('yes'),'P3 state missing: '+mode);
 assert(values.includes('ColorMode::SRGB (7)'),'active color missing: '+mode);
 assert(nodes['#bootlog'].textContent.includes('WCG_PROPERTY_APPLIED'),'boot log missing: '+mode);
}
(async()=>{
  await test('string');
  await test('object');
  await test('promise');
  console.log('PASS: KernelSU WebUI bridge parsing, three response types');
})().catch(e=>{console.error(e);process.exitCode=1});
