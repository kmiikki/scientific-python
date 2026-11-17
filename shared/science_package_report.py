"""Pure package coverage/reporting for both runtime checkers; no package operations."""
import re

RELEASE_IMPORTS={'shap':'shap','pywavelets':'pywt','optuna':'optuna','plotly':'plotly',
                 'hypothesis':'hypothesis','polars':'polars','xgboost':'xgboost'}


def package_name(spec):
    # The platform validator admits named MatchSpecs. Versions/builds/attributes
    # do not change the identity; final MatchSpec semantics remain Micromamba's.
    match=re.match(r'^(?:[^\s]+::)?([A-Za-z0-9_][A-Za-z0-9_.-]*)(?=[\[=<>!~ ]|$)',spec)
    if not match:raise ValueError('Invalid named package request: '+str(spec))
    return match[1].lower()


def coverage(configuration,defaults,records,import_checks=()):
    required={package_name(s) for s in configuration['ScientificPackages']}
    release={package_name(s) for s in defaults['ScientificPackages']}
    installed={r['name'].lower() for r in records}
    checks=list(import_checks);groups={}
    for check in checks:groups.setdefault(check['package'],[]).append(check['status'])
    return {'scope':'effective-user-configuration','status':'FAIL' if required-installed or any(c['status']=='FAIL' for c in checks) else 'PASS',
            'effective_requested':sorted(required),'release_defaults':sorted(release),'installed':sorted(installed),
            'release_default_coverage':'COMPLETE' if release<=installed else 'INCOMPLETE',
            'release_default_requests':'ALL_REQUESTED' if release<=required else 'DIFFERS',
            'missing_effective':sorted(required-installed),'release_not_requested':sorted(release-required),
            'release_not_installed':sorted(release-installed),'user_extra_requests':sorted(required-release),
            'verified_imports':sorted(p for p,statuses in groups.items() if all(s=='PASS' for s in statuses)),
            'imports_not_checked':sorted(required-set(groups)),'import_checks':checks}
