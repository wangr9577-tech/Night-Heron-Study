import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import {pathToFileURL} from 'node:url';

const modulePath = process.env.ZHUOZHI_ARTIFACT_MODULE || path.join(os.homedir(), '.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/@oai/artifact-tool/dist/artifact_tool.mjs');
try {
  const {FileBlob,PresentationFile}=await import(pathToFileURL(modulePath).href);
  const [input,directory]=process.argv.slice(2);
  await fs.mkdir(directory,{recursive:true});
  const presentation=await PresentationFile.importPptx(await FileBlob.load(input));
  for(const [index,slide] of presentation.slides.items.entries()) {
    const blob=await presentation.export({slide,format:'png',scale:1});
    await fs.writeFile(path.join(directory,`slide-${index+1}.png`),new Uint8Array(await blob.arrayBuffer()));
  }
  console.log(JSON.stringify({slideCount:presentation.slides.items.length}));
  for(const name of await fs.readdir(directory)) {
    const match=/^slide-(\d+)\.png$/.exec(name);
    if(match && Number(match[1])>presentation.slides.items.length) await fs.unlink(path.join(directory,name));
  }
  // All exports are awaited. Explicit termination avoids native renderer teardown errors on Windows.
  process.exit(0);
} catch(error) {
  console.error(error.stack || error);
  process.exit(1);
}
