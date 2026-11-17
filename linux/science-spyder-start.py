#!/usr/bin/env python3
"""Validate the activated frontend, then replace this process with Spyder."""
import importlib.util
import json
import os
from pathlib import Path
import sys
import uuid


def load_support_module(name, filename):
    """Load a support file by location without changing Python's import path."""
    path = Path(__file__).resolve().parent / filename
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def configure_frontend(prefix, test_profile=None):
    # A dedicated profile prevents another Spyder installation's interpreter and
    # single-instance server from redirecting this launch to a foreign kernel.
    manager = load_support_module('science_frontend_manager', 'science-manager.py')
    config_dir = Path(test_profile) if test_profile is not None else manager.prepare_settings(prefix.parent.parent)
    os.environ['SPYDER_CONFDIR'] = str(config_dir)
    from spyder.config.manager import CONF
    CONF.set('main_interpreter', 'default', True)
    CONF.set('main_interpreter', 'custom', False)
    CONF.set('main_interpreter', 'executable', str(prefix / 'bin/python'))
    return config_dir


def startup_tools():
    return load_support_module('science_spyder_startup', 'science_startup.py')


def launch(arguments, prefix=None, execv=os.execv):
    prefix = Path(prefix) if prefix is not None else Path(sys.prefix)
    runtime = load_support_module('science_frontend_runtime', 'science-runtime-check.py')
    context = runtime.identity(prefix)
    context['status'] = 'PASS'
    # Spyder 6.1.8 find_conda prefers CONDA_EXE over MAMBA_EXE. Do not inherit
    # another distribution's executable when starting from an existing shell.
    mm = Path(os.environ.get('MAMBA_EXE', str(prefix.parent.parent / 'bin/micromamba')))
    os.environ.update(CONDA_EXE=str(mm), MAMBA_EXE=str(mm), MAMBA_ROOT_PREFIX=str(prefix.parent.parent))
    arguments = list(arguments)
    startup = startup_tools()
    test_profile = None
    if '--science-startup-probe' in arguments:
        import resource
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        index = arguments.index('--science-startup-probe')
        control = arguments[index + 1]; del arguments[index:index + 2]
        sys.argv = [str(prefix / "bin/spyder")] + arguments
        test_profile = startup.instrument(control)
    elif not any(a in arguments for a in ['--help','--version','-h']):
        pending = prefix.parent.parent / 'science-spyder-startup.json'
        if pending.is_file() and json.loads(pending.read_text()).get('status') in ['PENDING','SKIP'] and startup.graphical_session(os.environ):
            report = startup.run(prefix, Path.home() / '.local/bin/science-spyder')
            if report['status'] != 'PASS': raise RuntimeError('Pending Spyder startup validation did not pass. See ' + str(pending))
    launch_id = uuid.uuid4().hex
    os.environ['SCIENCE_SPYDER_LAUNCH_ID'] = launch_id
    context['launch_id'] = launch_id
    context['frontend_pid'] = os.getpid()
    if test_profile is None:
        receipts = prefix.parent.parent / '.science-launch'
        receipts.mkdir(exist_ok=True)
        (receipts / (launch_id + '.json')).write_text(json.dumps(context, indent=2) + '\n', encoding='utf-8')
        output = prefix.parent.parent / 'science-launch-context.json'
        output.write_text(json.dumps(context, indent=2) + '\n', encoding='utf-8')
    configure_frontend(prefix, test_profile)
    if '--new-instance' not in arguments: arguments.insert(0, '--new-instance')
    spyder = prefix / 'bin/spyder'
    if not spyder.is_file():
        raise RuntimeError('Spyder executable missing')
    if test_profile is not None:
        from spyder.app.start import main
        sys.argv = [str(spyder)] + arguments
        main()
    else:
        execv(str(spyder), [str(spyder)] + list(arguments))


if __name__ == '__main__':
    try:
        launch(sys.argv[1:])
    except Exception as exc:
        print('Spyder activation failed (' + type(exc).__name__ + '): ' + str(exc) + '. Use menu D for diagnostics.', file=sys.stderr)
        sys.exit(1)
