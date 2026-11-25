Ano runtime 5.0.1, for **Ano 9 and later**. It replaces 5.0.0; Ano 9 offers it through its update check. Ano 8 stays on runtime 4.9.0, and Ano 6 and 7 stay on 3.1.6.

**What it is:** runtime 5.0.0's engine (Wine 11.19 with CrossOver's macOS patches, dappermint/winecx `9f3f644`, GPTK-capable, DXVK and DXMT built from source, wine-mono bundled) with two more changes, so that a Windows program finds no "wine" by name:
- **The copyright line** in every module's version information now reads "Copyright (c) 1993-2026 the authors listed in the file AUTHORS". The authors and the license are unchanged; the AUTHORS file and the license texts are in `Libraries/Ano/share/ano/licenses/engine/`.
- **Apple's D3DMetal** still uses a few of Wine's old names. ntdll no longer lists them among its functions. A DLL with D3DMetal's old mark gets them in its own memory (its file is not changed), and the engine keeps the old text encoded. D3DMetal's two settings (`WINED3DMETAL`, `WINEESYNC`) are set only in a process that loads D3DMetal.

**Bottles:** bottles made with runtime 5.0.0 keep working. On their first start with 5.0.1, the engine refreshes the Windows files in them, as it does after any engine update.

**Checked:** Ano Engine's check job builds a stand-in DLL with D3DMetal's old mark. The stand-in still finds the engine's functions three ways (its imports, `GetProcAddress`, `RtlFindExportedRoutineByName`). It also finds its own old-named export, a forward to an old ntdll name, and old names it builds while running. Its file is unchanged. An ordinary program finds none of the old names. Only Apple's real D3DMetal can confirm the rest, so it is part of the owner's test.

**Licenses:** as in 5.0.0. The engine is free software under the GNU Lesser General Public License, version 2.1 or later. The bundled components' own license texts are in `Libraries/Ano/share/ano/licenses/`, and `Libraries/Ano/share/ano/NOTICES` lists each component, its license, where its source is, and what Ano changed. The GPTK helper DLLs come from an upstream that publishes no license, and NOTICES says so; some libraries built into a component (for example MoltenVK's) have no text of their own yet.

**Source and build:**
- Repository: https://github.com/HighStormPVP/AnoWine
- Build script: https://github.com/HighStormPVP/AnoWine/blob/12c7f8426cda18bc1f367b971fb4e3e4f134deac/scripts/anowine/build-engine.sh
- Rename and patches: https://github.com/HighStormPVP/AnoWine/blob/12c7f8426cda18bc1f367b971fb4e3e4f134deac/scripts/anowine/rename_sources.py and https://github.com/HighStormPVP/AnoWine/tree/12c7f8426cda18bc1f367b971fb4e3e4f134deac/scripts/anowine/patches/rename
- Built and checked by Ano Engine run 45616091155: https://github.com/HighStormPVP/AnoWine/actions/runs/45616091155

SHA-256 of `Libraries.tar.gz`: 05998574c5d2010c5ebf0dac2f79e4a63314bbe04c76557d102a778164b246e1
