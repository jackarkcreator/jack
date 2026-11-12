# Jack for Windows tray app: smoke test on CI (windows-latest). Drives the real Jack.exe the way
# Explorer does (one process per selected file, all at once) and checks:
#   - one app instance, every other process hands over its file and exits 0
#   - files arriving together land on ONE card per kind (Word, Make Searchable, photos)
#   - outputs beside the PDFs (Word, searchable), photos PDF saved; refusals leave no file
#   - the inputs are byte-identical afterwards
#   - the drop window classifies 1 PDF / 2 PDFs / photos / mixed
#   - every button and progress bar has an accessible name (Narrator)
#   - Explorer verbs register and unregister under HKCU
# PNGs of every card / drop window state and state.json land in -Out (JACK_APP_TEST_DIR).
param([string]$App, [string]$Corpus, [string]$Out)
$ErrorActionPreference = 'Stop'
$exe = (Resolve-Path (Join-Path $App 'Jack.exe')).Path
$Out = New-Item -ItemType Directory $Out -Force | Select-Object -ExpandProperty FullName
$work = Join-Path $env:RUNNER_TEMP 'app work'          # a space, as real paths have
New-Item -ItemType Directory $work -Force | Out-Null
$fails = New-Object System.Collections.Generic.List[string]
function Check([bool]$ok, [string]$what) { if ($ok) { Write-Host "ok: $what" } else { Write-Host "FAIL: $what"; $fails.Add($what) } }

foreach ($f in 'memo.pdf', 'contract-2page.scan.pdf', 'price-table.pdf', 'letter-plain.scan.pdf', 'letter-plain.pdf') {
  Copy-Item (Join-Path $Corpus $f) $work
}
Add-Type -AssemblyName System.Drawing
foreach ($n in 'photo 1', 'photo 2') {
  $bmp = New-Object System.Drawing.Bitmap 1200, 900
  $g = [System.Drawing.Graphics]::FromImage($bmp); $g.Clear([System.Drawing.Color]::SteelBlue)
  $g.DrawString($n, (New-Object System.Drawing.Font 'Arial', 60), [System.Drawing.Brushes]::White, 100, 300); $g.Dispose()
  $bmp.Save((Join-Path $work "$n.png"), [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
}
$before = @{}; Get-ChildItem $work | ForEach-Object { $before[$_.Name] = (Get-FileHash $_.FullName -Algorithm SHA256).Hash }

$env:JACK_APP_TEST_DIR = $Out
$desk = [Environment]::GetFolderPath('Desktop')
$deskBefore = @(Get-ChildItem $desk -Filter 'Jack_*.pdf' -ErrorAction SilentlyContinue | ForEach-Object Name)
$primary = Start-Process $exe -ArgumentList '--tray' -PassThru
Start-Sleep -Seconds 2
Check (-not $primary.HasExited) 'app starts and stays in the tray'

function Launch([string]$verb, [string[]]$files) {
  $a = @($verb) + ($files | ForEach-Object { "`"$(Join-Path $work $_)`"" })
  Start-Process $exe -ArgumentList ($a -join ' ') -PassThru
}
# Explorer-style: one process per file, all at once.
$hand = @()
$hand += 'memo.pdf', 'contract-2page.scan.pdf', 'price-table.pdf' | ForEach-Object { Launch '--to-word' @($_) }
$hand += 'letter-plain.scan.pdf', 'letter-plain.pdf' | ForEach-Object { Launch '--searchable' @($_) }
$hand += 'photo 1.png', 'photo 2.png' | ForEach-Object { Launch '--photos' @($_) }
foreach ($h in $hand) { $h.WaitForExit(30000) | Out-Null }
Check (@($hand | Where-Object { -not $_.HasExited -or $_.ExitCode -ne 0 }).Count -eq 0) 'every Explorer-style process handed over its file and exited 0'
Check (@(Get-Process Jack -ErrorAction SilentlyContinue).Count -eq 1) 'one Jack process running'

# Drop window states (each replaces the staged files).
foreach ($set in @(@('memo.pdf'), @('memo.pdf', 'price-table.pdf'), @('photo 1.png', 'photo 2.png'), @('memo.pdf', 'photo 1.png'))) {
  $d = Launch '--drop' $set; $d.WaitForExit(15000) | Out-Null; Start-Sleep -Milliseconds 800
}

# Wait for the work to finish.
$state = $null
$deadline = (Get-Date).AddMinutes(6)
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 2
  try { $state = Get-Content (Join-Path $Out 'state.json') -Raw | ConvertFrom-Json } catch { continue }
  $kinds = @($state.batches | ForEach-Object kind)
  if ($state.idle -and $kinds.Count -ge 3 -and -not ($state.batches | Where-Object running)) { break }
}
$state | ConvertTo-Json -Depth 6 | Write-Host
$q = Launch '--quit' @(); $q.WaitForExit(15000) | Out-Null
Check ($primary.WaitForExit(60000)) 'app quits on --quit once the work is done'

function Batch([string]$k) { @($state.batches | Where-Object kind -eq $k) }
function Job([string]$k, [string]$file) { (Batch $k).jobs | Where-Object { $_.inputs -contains (Join-Path $work $file) } }
Check ((Batch 'Word').Count -eq 1 -and @((Batch 'Word')[0].jobs).Count -eq 3) 'three Word files gathered onto one card'
Check ((Batch 'Searchable').Count -eq 1 -and @((Batch 'Searchable')[0].jobs).Count -eq 2) 'two searchable files on one card'
Check ((Batch 'Photos').Count -eq 1 -and @((Batch 'Photos')[0].jobs).Count -eq 1 -and @((Batch 'Photos')[0].jobs[0].inputs).Count -eq 2) 'two photos gathered into one PDF job'

Check ((Job 'Word' 'memo.pdf').state -eq 'Done' -and (Test-Path (Join-Path $work 'memo.docx'))) 'memo.pdf saved as memo.docx beside it'
Check ((Job 'Word' 'contract-2page.scan.pdf').state -eq 'Done' -and (Test-Path (Join-Path $work 'contract-2page.scan.docx'))) 'scanned contract saved as Word'
Check ((Job 'Word' 'price-table.pdf').state -eq 'Refused' -and -not (Test-Path (Join-Path $work 'price-table.docx'))) 'table PDF refused, no file left'
Check ((Job 'Searchable' 'letter-plain.scan.pdf').state -eq 'Done' -and (Test-Path (Join-Path $work 'letter-plain.scan (searchable).pdf'))) 'scan made searchable beside it'
Check ((Job 'Searchable' 'letter-plain.pdf').state -eq 'NothingToDo' -and -not (Test-Path (Join-Path $work 'letter-plain (searchable).pdf'))) 'text PDF: already searchable, no copy'
$photoOut = (Batch 'Photos')[0].jobs[0].output
Check ((Batch 'Photos')[0].jobs[0].state -eq 'Done' -and $photoOut -and (Test-Path $photoOut)) "photos combined into $photoOut"
if ($photoOut -and (Test-Path $photoOut) -and ($deskBefore -notcontains (Split-Path $photoOut -Leaf))) { Copy-Item $photoOut $Out; Remove-Item $photoOut }

$changed = @($before.Keys | Where-Object { (Get-FileHash (Join-Path $work $_) -Algorithm SHA256).Hash -ne $before[$_] })
Check ($changed.Count -eq 0) "inputs byte-identical afterwards ($($changed -join ', '))"
Check (@(Get-ChildItem $work -Force | Where-Object Name -like '*.tmp').Count -eq 0) 'no temporary files left'

$pngs = @(Get-ChildItem $Out -Filter '*.png' | ForEach-Object Name)
foreach ($k in 'card-word', 'card-searchable', 'card-photos', 'drop') { Check (@($pngs | Where-Object { $_ -like "*-$k.png" }).Count -gt 0) "screenshots of $k" }
Check (@($pngs | Where-Object { $_ -like '*-drop.png' }).Count -ge 4) 'drop window: 1 PDF, 2 PDFs, photos and mixed states drawn'
$un = Join-Path $Out 'unnamed.txt'
Check (-not (Test-Path $un)) "every button and progress bar has an accessible name $(if (Test-Path $un) { Get-Content $un -Raw })"

$log = Join-Path $env:LOCALAPPDATA 'Jack\jack.log'
if (Test-Path $log) { Copy-Item $log $Out; Check (-not (Select-String -Path $log -Pattern 'ui error|job crashed|test shot' -Quiet)) 'no errors in jack.log' }

# Explorer verbs (this user).
& $exe --register | Out-Null; Start-Sleep -Seconds 1
$k = 'HKCU:\Software\Classes\SystemFileAssociations'
$cmd = (Get-ItemProperty "$k\.pdf\shell\Jack.ToWord\command").'(default)'
Check ($cmd -eq "`"$exe`" --to-word `"%1`"") "Convert to Word verb registered ($cmd)"
Check (Test-Path "$k\.pdf\shell\Jack.Searchable\command") 'Make searchable verb registered'
Check (Test-Path "$k\image\shell\Jack.Photos\command") 'photos verb registered'
& $exe --unregister | Out-Null; Start-Sleep -Seconds 1
Check (-not (Test-Path "$k\.pdf\shell\Jack.ToWord")) 'verbs removed on --unregister'

if ($fails.Count -gt 0) { Write-Host "`n$($fails.Count) check(s) failed"; exit 1 }
Write-Host "`nall checks passed"
exit 0
