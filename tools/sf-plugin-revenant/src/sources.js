// Finds the .cls files to lint.
import { existsSync, readdirSync, readFileSync, realpathSync, statSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";

/**
 * Reads the package directories of the nearest sfdx-project.json at or above
 * `start`.
 * @returns {{root: string, dirs: string[], missing: string[]} | null}
 */
export function projectSourceDirs(start) {
  let dir = resolve(start);
  for (;;) {
    const file = join(dir, "sfdx-project.json");
    if (existsSync(file)) {
      let project;
      try {
        project = JSON.parse(readFileSync(file, "utf8"));
      } catch (e) {
        throw new Error(`${file} is not valid JSON: ${e.message}`);
      }
      const entries = project?.packageDirectories ?? [];
      if (!Array.isArray(entries) || entries.some((p) => typeof p?.path !== "string")) {
        throw new Error(`${file}: each packageDirectories entry must have a "path" string.`);
      }
      const all = entries.map((p) => resolve(dir, p.path));
      return {
        root: dir,
        dirs: all.filter((d) => existsSync(d)),
        missing: all.filter((d) => !existsSync(d)),
      };
    }
    const parent = dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
}

/**
 * Reads each path: a .cls file, or the .cls files below a directory. The walk
 * skips hidden directories, node_modules and symbolic links.
 * @param {string[]} paths Files or directories.
 * A file that two paths reach is read one time.
 * @param {string} base Report paths are relative to this directory.
 * @returns {{path: string, source: string}[]}
 */
export function collectSources(paths, base) {
  const out = [];
  const seen = new Set();
  const add = (file) => {
    // A file that is not Apex must not count as a scanned file.
    if (!file.toLowerCase().endsWith(".cls")) throw new Error(`${file} is not a .cls file`);
    const real = realpathSync(file);
    if (seen.has(real)) return;
    seen.add(real);
    out.push({ path: relative(base, file), source: readFileSync(file, "utf8") });
  };
  const walk = (dir) => {
    const entries = readdirSync(dir, { withFileTypes: true }).sort((a, b) =>
      a.name < b.name ? -1 : a.name > b.name ? 1 : 0,
    );
    for (const e of entries) {
      const full = join(dir, e.name);
      if (e.isDirectory()) {
        if (!e.name.startsWith(".") && e.name !== "node_modules") walk(full);
      } else if (e.isFile() && e.name.toLowerCase().endsWith(".cls")) {
        add(full);
      }
    }
  };
  for (const p of paths) {
    const full = resolve(base, p);
    if (statSync(full).isDirectory()) {
      walk(full);
    } else {
      add(full);
    }
  }
  return out;
}
