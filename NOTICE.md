# NOTICE — third-party components

This repository contains prebuilt Microsoft binaries under `src/cwatch/` and
`src/cwatch/lib/`. They are **not** covered by this project's MIT license
(see [LICENSE](LICENSE)); they are provided by Microsoft and are used here as
build/runtime dependencies of the ETW collector (`CWatch.cs` → `cwatch.exe`).

| Component | Files | Origin | Terms |
|---|---|---|---|
| TraceEvent / FastSerialization | `Microsoft.Diagnostics.Tracing.TraceEvent.dll`, `Microsoft.Diagnostics.Tracing.TraceEvent.xml`, `Microsoft.Diagnostics.FastSerialization.dll` | Microsoft PerfView / TraceEvent library | **MIT** (Microsoft) |
| Debug Interface Access (DIA) SDK | `msdia140.dll`, `Dia2Lib.dll` | Microsoft DIA SDK, redistributed with Visual Studio | Microsoft license terms for the DIA SDK |
| Windows SDK tracing components | `KernelTraceControl.dll`, `OSExtensions.dll`, `TraceReloggerLib.dll` | Windows SDK / Microsoft redistributable components | Microsoft license terms |

Notes:

- These files were obtained from the vendors' own distributions (NuGet package /
  Visual Studio / Windows SDK). **Their licenses are the vendors' terms, not this
  project's.** If you redistribute this repository or a build of it, keep this
  notice and comply with those terms.
- The project includes them only because `cwatch.exe` is compiled against them and
  traces ETW sessions at runtime. The measurement scripts (`disk-sample.ps1`,
  `disk-report.ps1`, `disk-daily.ps1`, the dashboard and the tray) do not need
  them — you can delete `src/cwatch/` if you only want the per-disk numbers.
- `src/cwatch/CWatch.cs`, `CwtDump.cs`, `build.ps1` and the rest of the source in
  this repository are original work and are covered by the MIT license.

If you are a rights holder and believe a file should not be redistributed here,
open an issue and it will be removed.
