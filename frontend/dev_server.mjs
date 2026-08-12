import { createReadStream, stat } from "node:fs";
import { createServer } from "node:http";
import { extname, isAbsolute, join, normalize, relative, resolve, sep } from "node:path";
import { pathToFileURL } from "node:url";

const root = normalize(join(import.meta.dirname, ".."));
const port = Number(process.env.PORT ?? 8765);
const types = {
  ".css": "text/css; charset=utf-8",
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
};

export function resolveRequestPath(pathname) {
  let decoded;
  try {
    decoded = decodeURIComponent(pathname);
  } catch {
    return null;
  }
  const path = resolve(root, `.${decoded}`);
  const rel = relative(root, path);
  if (rel === ".." || rel.startsWith(`..${sep}`) || isAbsolute(rel)) return null;
  return path;
}

function serve() {
  createServer((request, response) => {
    const pathname = new URL(request.url, "http://localhost").pathname;
    let path = resolveRequestPath(pathname);
    if (path === null) {
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
}

const entry = process.argv[1] ? pathToFileURL(resolve(process.argv[1])).href : "";
if (entry === import.meta.url) serve();
