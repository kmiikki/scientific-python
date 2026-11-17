#!/usr/bin/env python3
"""Run once in Spyder's first IPython console: %run <selected-root>/share/scientific-python/spyder-acceptance.py"""
import importlib.util
import json
from pathlib import Path
import shutil
import sys

support = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('science_spyder_acceptance', support / 'science-runtime-check.py')
runtime = importlib.util.module_from_spec(spec); spec.loader.exec_module(runtime)
prefix = Path(sys.prefix)
report = runtime.run_checks(prefix, gui_auto=True)
try:
    report['checks']['frontend'] = runtime.frontend_receipt(prefix)
except Exception as exc:
    report['checks']['frontend'] = {'status': 'FAIL', 'reason': 'Start Spyder with science-spyder or the GNOME entry', 'error_type': type(exc).__name__}
report['status'] = 'FAIL' if any(v['status'] == 'FAIL' for v in report['checks'].values()) else 'PASS'
output = prefix.parent.parent / 'science-spyder-kernel.json'
output.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
print('Python:', sys.executable)
print('FFmpeg:', shutil.which('ffmpeg'))
print('FFprobe:', shutil.which('ffprobe'))
print('Spyder acceptance:', report['status'])
print('Report:', output)
