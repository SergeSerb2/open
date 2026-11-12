// Applied only to the entry HTML while serving an external benchmark checkout.
// No benchmark files are changed. Hooks report only after the original result.
(() => {
  const cfg=window.openPerfBenchmark;
  const stage=error=>navigator.sendBeacon('/collect',new Blob([JSON.stringify({run:cfg.run,benchmark:cfg.name,event:'benchmark-stage',error})],{type:'application/json'}));
  stage('reporter-loaded');
  addEventListener('unhandledrejection',e=>navigator.sendBeacon('/collect',new Blob([JSON.stringify({run:cfg.run,benchmark:cfg.name,event:'benchmark-error',error:String(e.reason).slice(0,256)})],{type:'application/json'})));
  addEventListener('load', () => {
  stage('window-loaded');
  let reported=false;
  const send=(score,event='benchmark')=>{
    if(reported)return;reported=true;
    navigator.sendBeacon('/collect',new Blob([JSON.stringify({run:cfg.run,benchmark:cfg.name,event,score})],{type:'application/json'}));
  };
  if(cfg.name==='speedometer'){
    const client=globalThis.benchmarkClient;
    const originalError=client.handleError;
    client.handleError=function(...args){
      const result=originalError.apply(this,args);send(null);return result;
    };
    const original=client.didFinishLastIteration;
    client.didFinishLastIteration=function(...args){
      const result=original.apply(this,args);
      const scores=this._measuredValuesList.map(row=>row.score);
      send(scores.reduce((a,b)=>a+b,0)/scores.length);
      return result;
    };
    stage('starting-suite');client.start();
  } else if(cfg.name==='jetstream'){
    const original=JetStream.start;
    JetStream.start=async function(...args){
      try {
        const result=await original.apply(this,args);
        send(Math.exp(this.benchmarks.reduce((sum,b)=>sum+Math.log(b.score),0)/this.benchmarks.length));
        return result;
      } catch(error) {send(null);throw error;}
    };
    const timer=setInterval(()=>{
      if(document.querySelector('#status a')){clearInterval(timer);stage('starting-suite');JetStream.start();}
    },50);
  } else if(cfg.name==='motionmark'){
    const original=benchmarkRunnerClient.didFinishLastIteration;
    benchmarkRunnerClient.didFinishLastIteration=function(...args){
      const result=original.apply(this,args);send(this.results.score);return result;
    };
    const timer=setInterval(()=>{
      if(!document.querySelector('#start-button').disabled){
        clearInterval(timer);
        const p=benchmarkController.benchmarkDefaultParameters;
        stage('starting-suite target-fps='+p['frame-rate']+' system-fps='+p['system-frame-rate']);
        benchmarkController.startBenchmark();
      }
    },50);
  }
}, {once:true});
})();
