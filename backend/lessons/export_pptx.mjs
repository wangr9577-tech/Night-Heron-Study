// Editable lesson deck generated from the exact same page/element IDs used by A's player.
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import {pathToFileURL} from 'node:url';

async function loadRenderer() {
  if (process.env.ZHUOZHI_ARTIFACT_MODULE) return import(pathToFileURL(process.env.ZHUOZHI_ARTIFACT_MODULE).href);
  try { return await import('@oai/artifact-tool'); } catch {}
  const modulePath = path.join(os.homedir(), '.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/@oai/artifact-tool/dist/artifact_tool.mjs');
  return import(pathToFileURL(modulePath).href);
}
const {Presentation, PresentationFile, FileBlob} = await loadRenderer();
const [source, dest] = process.argv.slice(2);
const lesson = JSON.parse(await fs.readFile(source, 'utf8'));
const presentation = Presentation.create({slideSize: {width:1280, height:720}});
const font = process.env.ZHUOZHI_SLIDE_FONT || 'Microsoft YaHei';
function textbox(slide, id, text, left, top, width, height, size, color, bold=false) {
  const shape = slide.shapes.add({geometry:'textbox', name:id, position:{left,top,width,height}, fill:'none', line:{fill:'none',width:0}});
  shape.text = text;
  shape.text.style = {typeface:font,fontSize:size,color,bold,wrap:true};
}
for (const [index,page] of lesson.pages.entries()) {
  const slide = presentation.slides.add();
  slide.background.fill = '#FFFFFF';
  textbox(slide,page.page_id+'_title',page.title,72,46,1136,80,38,'#183F46',true);
  for (const [i,element] of page.elements.entries()) {
    textbox(slide,element.element_id,element.text,72,154+i*146,1136,130,28,'#24383E');
  }
  const refs = page.elements.flatMap(e=>e.source_refs || []);
  const labels = [...new Set(refs.map(r=>`资料 ${r.material_id.slice(0,12)} 第 ${r.page} 页`))].join('；');
  textbox(slide,page.page_id+'_source',`${labels}    ${index+1}/${lesson.pages.length}`,72,646,1136,36,16,'#657879');
  slide.speakerNotes.text = page.narration_segments.map(s=>`${s.segment_id}: ${s.text}`).join('\n')+'\n'+JSON.stringify(refs);
}
const candidate = dest.replace(/\.pptx$/i,'.draft.pptx');
await (await PresentationFile.exportPptx(presentation)).save(candidate);
// Reimport validates that the exported package is readable before atomic publication.
await PresentationFile.importPptx(await FileBlob.load(candidate));
await fs.rename(candidate,dest);
