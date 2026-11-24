Ano runtime 5.0.0, for **Ano 9 and later**. Ano 8 stays on runtime 4.9.0, and Ano 6 and 7 stay on 3.1.6; their feeds still point there.

**What it is:** the same engine as runtime 4.9.0, now built by this repository and renamed. It is Wine 11.19 with CrossOver's macOS patches (dappermint/winecx `9f3f644`), GPTK-capable, with DXVK and DXMT built from source and wine-mono bundled.

**What changed:** the engine's files, programs, settings and registry no longer use the name "wine", except where a license text or a closed component needs it:
- programs are `ano-loader`, `ano-server`, `ano-boot`, `ano-cfg` and the like;
- settings are `ANOPREFIX` and `ANODEBUG`;
- the registry key is `Software\Ano`;
- the folders are `lib/ano` and `share/ano`.

Two hidden aliases remain for Apple's closed D3DMetal: `WINED3DMETAL` and `WINEESYNC`.

**Bottles:** bottles made with an earlier runtime are not converted. Ano 9 lists them but will not open them, so make them again.

**Licenses:** the engine is free software under the GNU Lesser General Public License, version 2.1 or later. Every bundled component's own license text is in `Libraries/Ano/share/ano/licenses/`. `Libraries/Ano/share/ano/NOTICES` lists each component, its license, where its source is, and what Ano changed.

**Source and build:**
- Repository: https://github.com/HighStormPVP/AnoWine
- Build script: https://github.com/HighStormPVP/AnoWine/blob/11057786905618b9ad6add5a7eb997aabd6a294d/scripts/anowine/build-engine.sh
- Rename: https://github.com/HighStormPVP/AnoWine/blob/11057786905618b9ad6add5a7eb997aabd6a294d/scripts/anowine/rename_sources.py and https://github.com/HighStormPVP/AnoWine/tree/11057786905618b9ad6add5a7eb997aabd6a294d/scripts/anowine/patches/rename
- Built and checked by Ano Engine run 45326779119: https://github.com/HighStormPVP/AnoWine/actions/runs/45326779119

SHA-256 of `Libraries.tar.gz`: 6e247eca99aaa2a4863905a5ba6f3eca112abe5aade85382c9b423768892987b
