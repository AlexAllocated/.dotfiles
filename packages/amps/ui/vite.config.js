import { defineConfig } from "vite";
import { readFileSync, existsSync } from "node:fs";
import { dirname, join, parse } from "node:path";
export default defineConfig({
	base: "./",
	publicDir: "public",
	build: { outDir: "web", emptyOutDir: true, sourcemap: false },
	plugins: [
		{
			name: "amps-dependency-notices",
			generateBundle() {
				const packages = new Map();
				for (const id of this.getModuleIds()) {
					if (!id.includes("node_modules")) continue;
					let folder = dirname(id.split("?")[0]);
					while (folder !== parse(folder).root && !existsSync(join(folder, "package.json")))
						folder = dirname(folder);
					if (!existsSync(join(folder, "package.json"))) continue;
					const pkg = JSON.parse(readFileSync(join(folder, "package.json"), "utf8"));
					const licenseFile = ["LICENSE", "LICENSE.md", "LICENSE.txt", "LICENSE-MIT"].find(
						file => existsSync(join(folder, file))
					);
					packages.set(
						pkg.name,
						`${pkg.name} ${pkg.version} — ${pkg.license}\n${JSON.stringify(pkg.repository ?? pkg.homepage ?? "")}\n${licenseFile ? readFileSync(join(folder, licenseFile), "utf8") : "See the package source for license text."}`
					);
				}
				this.emitFile({
					type: "asset",
					fileName: "third-party-notices.txt",
					source: [...packages.values()].sort().join("\n\n====================\n\n")
				});
			}
		}
	]
});
