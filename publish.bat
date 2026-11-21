@echo off
rem Re-exports the game for the web (docs/), commits everything and pushes to GitHub.
rem GitHub Pages then redeploys automatically from main /docs.
setlocal
cd /d "%~dp0"

set "GODOT=C:\Godot\Godot_v4.7.2-stable_win64_console.exe"
if not exist "%GODOT%" (
    echo Godot not found at %GODOT%
    exit /b 1
)

echo === Exporting Web build to docs\index.html ===
if not exist docs mkdir docs
"%GODOT%" --headless --path . --export-release "Web" docs/index.html
if errorlevel 1 (
    echo Export failed.
    exit /b 1
)
if not exist docs\index.html (
    echo Export failed: docs\index.html was not created.
    exit /b 1
)

rem Keep Godot from importing the exported files back into the project.
if not exist docs\.gdignore type nul > docs\.gdignore

echo === Committing ===
git add -A
git diff --cached --quiet
if errorlevel 1 (
    git commit -m "Publish web build"
    if errorlevel 1 exit /b 1
) else (
    echo Nothing new to commit.
)

echo === Pushing ===
git push origin main
if errorlevel 1 (
    echo Push failed.
    exit /b 1
)

echo === Done. Pages will update in a minute or two. ===
endlocal
