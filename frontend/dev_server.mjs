import { createReadStream, stat } from "node:fs";
import { createServer } from "node:http";
import { extname, join, normalize } from "node:path";

const root = normalize(join(import.meta.dirname, ".."));
const port = Number(process.env.PORT ?? 8765);
const types = {
  ".css": "text/css; charset=utf-8",
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
};

createServer((request, response) => {
  const pathname = decodeURIComponent(new URL(request.url, "http://localhost").pathname);
  let path = normalize(join(root, pathname));
  if (!path.startsWith(root)) {
    response.writeHead(403).end("Forbidden");
    return;
  }
  stat(path, (error, entry) => {
    if (!error && entry.isDirectory()) path = join(path, "index.html");
    stat(path, (fileError, file) => {
      if (fileError || !file.isFile()) {
        response.writeHead(404).end("Not found");
        return;
      }
      response.writeHead(200, { "Content-Type": types[extname(path)] ?? "application/octet-stream" });
      createReadStream(path).pipe(response);
    });
  });
}).listen(port, "127.0.0.1", () => {
  console.log(`MoonSage frontend: http://127.0.0.1:${port}/frontend/`);
});
