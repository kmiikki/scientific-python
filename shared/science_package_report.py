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


PYTORCH_REQUESTS = frozenset({'pytorch', 'pytorch-cpu', 'pytorch-gpu'})
PYTORCH_BUILD_ATTRIBUTE = re.compile(
    r'''(?:\[|,)\s*build\s*=\s*(?P<quote>['"]?)(?P<build>[\w.*+-]+)(?P=quote)\s*(?=[,\]])'''
)
PYTORCH_POSITIONAL_BUILD = re.compile(r'^(?:[^\s]+::)?pytorch(?:==?[\w.*+!-]+=|\s+[^\s\[]+\s+)([\w.*+-]+)\s*$', re.I)


def pytorch_backend(specs):
    # Describe the request independently of what is installed.
    backends = set()
    for spec in specs:
        name = package_name(spec)
        if name in ('pytorch-cpu', 'pytorch-gpu'):
            backends.add('cpu' if name == 'pytorch-cpu' else 'cuda')
        elif name == 'pytorch':
            attr = PYTORCH_BUILD_ATTRIBUTE.search(spec)
            positional = PYTORCH_POSITIONAL_BUILD.search(spec)
            build = attr['build'] if attr else positional[1] if positional else ''
            backends.add(next((backend for backend in ('cpu', 'cuda') if build.startswith(backend)), 'automatic'))
    if len(backends) > 1:
        backends.discard('automatic')
    if len(backends) > 1:
        return 'conflicting'
    return next(iter(backends), 'none')


def pytorch_probe(requested, backend=None):
    """Verify the actual backend when the user explicitly requests PyTorch."""
    if not PYTORCH_REQUESTS.intersection(requested):
        return None
    import torch

    if (backend == 'cpu' or 'pytorch-cpu' in requested) and torch.version.cuda is not None:
        raise RuntimeError('The requested CPU-only PyTorch is a CUDA build.')
    matrix = torch.tensor([[1.0, 2.0], [3.0, 4.0]], device='cpu', requires_grad=True)
    product = matrix @ matrix
    expected = [[7.0, 10.0], [15.0, 22.0]]
    if product.tolist() != expected:
        raise RuntimeError('PyTorch CPU matrix multiplication failed.')
    product.sum().backward()
    if matrix.grad is None or matrix.grad.tolist() != [[7.0, 11.0], [9.0, 13.0]]:
        raise RuntimeError('PyTorch CPU autograd failed.')

    available = torch.cuda.is_available()
    if (backend == 'cuda' or 'pytorch-gpu' in requested) and not available:
        raise RuntimeError('PyTorch cannot access a compatible NVIDIA CUDA device.')
    report = {'version': str(torch.__version__), 'backend': 'cpu',
              'compiled_cuda': torch.version.cuda, 'cuda_available': available,
              'cpu_matrix_multiplication': True, 'autograd': True}
    if available:
        gpu = matrix.detach().to('cuda')
        gpu_product = gpu @ gpu
        torch.cuda.synchronize(gpu.device)
        if gpu_product.cpu().tolist() != expected:
            raise RuntimeError('PyTorch CUDA computation or transfer failed.')
        report.update(backend='cuda', device_name=torch.cuda.get_device_name(gpu.device),
                      compute_capability=list(torch.cuda.get_device_capability(gpu.device)),
                      cuda_matrix_multiplication=True, cpu_gpu_transfers=True, cuda_synchronized=True)
    return report
