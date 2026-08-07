# Mermaid HTML Template — Zoomable OST Diagrams

Reusable HTML template for rendering a full Opportunity-Solution Tree as a single interactive Mermaid diagram with zoom and pan.

## Key configuration

- `htmlLabels: false` — SVG text, no clipping
- Single-line labels only (no `<br/>`)
- Subgraphs for each branch
- Pure tree — no cross-subgraph edges
- Light background (`#f5f5f8`)

## CSS for visible arrows

```css
#canvas svg .edgePath .path { stroke-width: 2.5px !important; stroke: #666 !important; }
#canvas svg .marker { stroke: #666 !important; fill: #666 !important; }
```

## CSS for unclipped text

```css
#canvas svg .nodeLabel { line-height: 1.25 !important; }
```

## Zoom/pan JavaScript

The template provides mouse wheel zoom, click-drag pan, and touch support. Keyboard shortcuts: `+`/`=` zoom in, `-` zoom out, `0` reset.

Initial scale of 0.40-0.55 works well for trees with 60-100 nodes.

## Style class definitions

```mermaid
classDef corp fill:#1a1a2e,color:#fff,stroke:#333
classDef ost fill:#6d68ad,color:#fff,stroke:#4a4578
classDef metric fill:#e8e0f0,color:#333,stroke:#6d68ad
classDef sub fill:#fff,color:#333,stroke:#ccc
classDef done fill:#c8e6c9,color:#2e7d32,stroke:#81c784
classDef prog fill:#fff9c4,color:#f57f17,stroke:#f9a825
classDef todo fill:#e0e0e0,color:#888,stroke:#ccc
classDef xops fill:#f3e5f5,color:#6a1b9a,stroke:#ce93d8
classDef tbd fill:#fff3e0,color:#e65100,stroke:#ffb74d
classDef track fill:#e3f2fd,color:#1565c0,stroke:#90caf9
```

## Full template

```html
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>OST</title>
<script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{background:#f5f5f8;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;overflow:hidden;height:100vh;width:100vw}
#canvas svg .nodeLabel{line-height:1.25!important}
#canvas svg .node rect,#canvas svg .node polygon,#canvas svg .node ellipse{stroke-width:1.5px!important}
#canvas svg .edgePath .path{stroke-width:2.5px!important;stroke:#666!important}
#canvas svg .marker{stroke:#666!important;fill:#666!important}
#canvas svg .cluster rect{stroke:#bbb!important;stroke-width:2px!important;stroke-dasharray:6 4!important;rx:8px!important}
#canvas svg .cluster text{fill:#777!important;font-size:13px!important}
.controls{position:fixed;bottom:24px;right:24px;display:flex;gap:8px;z-index:100}
.controls button{width:40px;height:40px;border:1px solid #ccc;border-radius:8px;background:#fff;color:#333;font-size:20px;cursor:pointer;display:flex;align-items:center;justify-content:center;box-shadow:0 1px 4px rgba(0,0,0,.08)}
.controls button:hover{background:#f0f0f0}
.controls button.reset-btn{font-size:13px;width:auto;padding:0 12px}
.zoom-label{display:flex;align-items:center;justify-content:center;width:52px;height:40px;background:#fff;color:#666;border-radius:8px;font-size:13px;border:1px solid #ccc}
.legend{position:fixed;top:16px;left:16px;background:rgba(255,255,255,.95);border:1px solid #ddd;border-radius:8px;padding:10px 14px;z-index:100;display:flex;flex-wrap:wrap;gap:10px 16px;font-size:12px;color:#555;box-shadow:0 1px 4px rgba(0,0,0,.06)}
.legend-item{display:flex;align-items:center;gap:5px}
.legend-dot{width:12px;height:12px;border-radius:3px}
.canvas-container{width:100vw;height:100vh;overflow:hidden;cursor:grab}
.canvas-container:active{cursor:grabbing}
#canvas{transform-origin:0 0;transition:transform .12s ease-out;padding:30px 40px}
#canvas svg{max-width:none;height:auto}
</style></head><body>
<div class="controls"><button onclick="zoomIn()">+</button><div class="zoom-label" id="zoomLabel">100%</div><button onclick="zoomOut()">−</button><button class="reset-btn" onclick="zoomReset()">↺ Fit</button></div>
<div class="canvas-container" id="container"><div id="canvas"><pre class="mermaid">
%%{init:{'flowchart':{'nodeSpacing':18,'rankSpacing':38}}}%%
flowchart TD
    N1["Root Node"]
    N1 --> N2["Child"]
    classDef root fill:#1a1a2e,color:#fff,stroke:#333
    class N1 root
</pre></div></div>
<script>
mermaid.initialize({startOnLoad:true,theme:'default',flowchart:{useMaxWidth:false,htmlLabels:false,curve:'basis'}});
let scale=0.45,panX=20,panY=10,isPanning=false,startX,startY;
const canvas=document.getElementById('canvas'),container=document.getElementById('container'),zl=document.getElementById('zoomLabel');
function u(){canvas.style.transform=`translate(${panX}px,${panY}px) scale(${scale})`;zl.textContent=Math.round(scale*100)+'%'}
function zi(){scale=Math.min(scale*1.25,4);u()}
function zo(){scale=Math.max(scale*.8,.06);u()}
function zr(){scale=.45;panX=20;panY=10;u()}
container.addEventListener('wheel',e=>{e.preventDefault();const r=container.getBoundingClientRect(),mx=e.clientX-r.left,my=e.clientY-r.top,old=scale;scale=e.deltaY<0?Math.min(scale*1.1,4):Math.max(scale*.9,.06);panX=mx-(mx-panX)*(scale/old);panY=my-(my-panY)*(scale/old);u()},{passive:false});
container.addEventListener('mousedown',e=>{if(e.target.tagName==='BUTTON')return;isPanning=true;startX=e.clientX-panX;startY=e.clientY-panY});
window.addEventListener('mousemove',e=>{if(!isPanning)return;panX=e.clientX-startX;panY=e.clientY-startY;u()});
window.addEventListener('mouseup',()=>{isPanning=false});
container.addEventListener('touchstart',e=>{if(e.touches.length===1){isPanning=true;startX=e.touches[0].clientX-panX;startY=e.touches[0].clientY-panY}});
container.addEventListener('touchmove',e=>{if(!isPanning||e.touches.length!==1)return;panX=e.touches[0].clientX-startX;panY=e.touches[0].clientY-startY;u()});
container.addEventListener('touchend',()=>{isPanning=false});
window.addEventListener('keydown',e=>{if(e.key==='+'||e.key==='='){e.preventDefault();zi()}if(e.key==='-'){e.preventDefault();zo()}if(e.key==='0'){e.preventDefault();zr()}});
u();
</script></body></html>
```
