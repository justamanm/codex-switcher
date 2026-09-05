import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const rootDirectory = path.dirname(scriptDirectory);
const iconset = path.join(rootDirectory, "support", "AppIcon.iconset");
const output = path.join(rootDirectory, "support", "AppIcon.icns");

const entries = [
  ["icp4", "icon_16x16.png"],
  ["icp5", "icon_32x32.png"],
  ["ic07", "icon_128x128.png"],
  ["ic08", "icon_256x256.png"],
  ["ic09", "icon_512x512.png"],
  ["ic10", "icon_512x512@2x.png"],
  ["ic11", "icon_16x16@2x.png"],
  ["ic12", "icon_32x32@2x.png"],
  ["ic13", "icon_128x128@2x.png"],
  ["ic14", "icon_256x256@2x.png"],
];

const chunks = entries.map(([type, filename]) => {
  const image = fs.readFileSync(path.join(iconset, filename));
  const header = Buffer.alloc(8);
  header.write(type, 0, 4, "ascii");
  header.writeUInt32BE(image.length + 8, 4);
  return Buffer.concat([header, image]);
});

const header = Buffer.alloc(8);
header.write("icns", 0, 4, "ascii");
header.writeUInt32BE(chunks.reduce((sum, chunk) => sum + chunk.length, 8), 4);
fs.writeFileSync(output, Buffer.concat([header, ...chunks]), { mode: 0o644 });
console.log(`已生成图标：${output}`);
