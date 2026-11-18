"""Post-update scientific data/media acceptance. Creates only temporary datasets.

Run with the Science interpreter, normally through 08-data-acceptance.ps1.
Sample inputs are opened read-only, hashed before/after, and never deleted.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

def file_hash(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

def acceptance(prefix, expected_opencv='5.1.0', expected_hdf5='1.14.6', temp_root=None, samples=()):
    prefix=Path(prefix).resolve()
    result={'checks':{},'versions':{},'samples':[],'temporary_files_removed':False}
    def check(name,fn):
        try:
            value=fn()
            if value is False: raise AssertionError('Unexpected result')
            result['checks'][name]={'status':'PASS'}
            return value
        except Exception as exc:
            result['checks'][name]={'status':'FAIL','error_type':type(exc).__name__,'detail':str(exc)}
            return None
    if not check('science_interpreter',lambda:Path(sys.prefix).resolve()==prefix):
        result['success']=False
        return result
    modules={}
    for name in ['numpy','h5py','netCDF4','xarray','cv2','pyarrow']:
        module=check('import_'+name,lambda name=name:__import__(name))
        if module is not None:modules[name]=module;result['versions'][name]=getattr(module,'__version__','unknown')
    records={r['name']:r for p in (prefix/'conda-meta').glob('*.json') for r in [json.loads(p.read_text(encoding='utf-8-sig'))]}
    result['package_builds']={n:{'version':records[n]['version'],'build':records[n]['build']} for n in ['python','spyder','hdf5','h5py','libnetcdf','netcdf4','xarray','opencv','ffmpeg','pyarrow'] if n in records}
    check('python_314',lambda:sys.version_info[:2]==(3,14))
    check('spyder_618',lambda:records['spyder']['version']=='6.1.8')
    check('hdf5_package_version',lambda:records['hdf5']['version']==expected_hdf5)
    check('opencv_package_version_qt6',lambda:records['opencv']['version']==expected_opencv and records['opencv']['build'].startswith('qt6'))
    check('ffmpeg_package_9_gpl',lambda:records['ffmpeg']['version'].startswith('9.') and records['ffmpeg']['build'].startswith('gpl'))
    if 'h5py' in modules:
        result['versions']['hdf5_runtime_h5py']=modules['h5py'].version.hdf5_version
        check('h5py_hdf5_runtime',lambda:modules['h5py'].version.hdf5_version==expected_hdf5)
    if 'netCDF4' in modules:
        result['versions']['hdf5_runtime_netcdf4']=modules['netCDF4'].__hdf5libversion__
        result['versions']['libnetcdf_runtime']=modules['netCDF4'].getlibversion()
        check('netcdf4_hdf5_runtime',lambda:modules['netCDF4'].__hdf5libversion__==expected_hdf5)
        check('libnetcdf_runtime_matches_package',lambda:modules['netCDF4'].getlibversion().split()[0]==records['libnetcdf']['version'])
    if 'cv2' in modules:
        cv=modules['cv2'];info=cv.getBuildInformation()
        check('opencv_version',lambda:cv.__version__==expected_opencv)
        check('opencv_highgui_qt6_build',lambda:bool(re.search(r'GUI:\s+QT6',info)))
        check('opencv_ffmpeg_videoio_build',lambda:bool(re.search(r'FFMPEG:\s+YES',info)))
        # This checks compiled HighGUI support; it deliberately opens no GUI window.
    def ffmpeg_capabilities():
        exe=prefix/'Library/bin/ffmpeg.exe'
        completed=subprocess.run([str(exe),'-version'],capture_output=True,text=True,timeout=30,check=True)
        text=completed.stdout+completed.stderr
        if not re.search(r'ffmpeg version 9\.',text) or '--enable-gpl' not in text:return False
        return True
    check('ffmpeg_executable_9_gpl',ffmpeg_capabilities)
    with tempfile.TemporaryDirectory(prefix='science-data-acceptance-',dir=temp_root) as folder:
        directory=Path(folder)
        if 'numpy' in modules:
            np=modules['numpy'];array=np.arange(120,dtype=np.float64).reshape(4,5,6)/8
            if 'h5py' in modules:
                def hdf5_roundtrip():
                    h5=modules['h5py'];path=directory/'roundtrip.h5'
                    with h5.File(path,'w') as f:
                        d=f.create_dataset('values',data=array,compression='gzip',compression_opts=4,shuffle=True,fletcher32=True)
                        d.attrs['units']='test-unit';f.attrs['description']='Scientific Python acceptance'
                    with h5.File(path,'r') as f:
                        d=f['values'];np.testing.assert_array_equal(d[...],array)
                        assert d.compression=='gzip' and d.shuffle and d.fletcher32
                        assert d.attrs['units']=='test-unit' and f.attrs['description']=='Scientific Python acceptance'
                    return True
                check('hdf5_array_compression_attributes_roundtrip',hdf5_roundtrip)
            if 'netCDF4' in modules:
                def netcdf_roundtrip():
                    netcdf=modules['netCDF4'];path=directory/'roundtrip.nc'
                    with netcdf.Dataset(path,'w',format='NETCDF4') as f:
                        for name,size in zip(('t','y','x'),array.shape):f.createDimension(name,size)
                        d=f.createVariable('values','f8',('t','y','x'),zlib=True,complevel=4,shuffle=True)
                        d.units='test-unit';d[:]=array
                    with netcdf.Dataset(path,'r') as f:
                        d=f.variables['values'];assert d.dimensions==('t','y','x')
                        np.testing.assert_array_equal(d[:],array);assert d.units=='test-unit' and d.filters()['zlib']
                    return True
                check('netcdf4_dimensions_values_compression_roundtrip',netcdf_roundtrip)
                if 'xarray' in modules:
                    def xarray_roundtrip():
                        xr=modules['xarray'];path=directory/'xarray.nc'
                        source=xr.Dataset({'values':(('t','y','x'),array)},attrs={'description':'acceptance'})
                        source.to_netcdf(path,engine='netcdf4',encoding={'values':{'zlib':True,'complevel':4}})
                        with xr.open_dataset(path,engine='netcdf4') as f:
                            np.testing.assert_array_equal(f['values'].values,array)
                            assert tuple(f['values'].dims)==('t','y','x') and f.attrs['description']=='acceptance'
                        return True
                    check('xarray_netcdf4_roundtrip',xarray_roundtrip)
            if 'pyarrow' in modules:
                def arrow_roundtrip():
                    import pyarrow.parquet as parquet
                    pa=modules['pyarrow'];path=directory/'roundtrip.parquet'
                    table=pa.table({'index':np.arange(array.size),'value':array.ravel()})
                    parquet.write_table(table,path,compression='snappy')
                    assert parquet.read_table(path).equals(table)
                    return True
                check('pyarrow_parquet_roundtrip',arrow_roundtrip)
            if 'cv2' in modules:
                cv=modules['cv2'];image=np.random.default_rng(1729).integers(0,256,(48,64,3),dtype=np.uint8)
                def image_roundtrip():
                    ok,encoded=cv.imencode('.png',image);assert ok
                    decoded=cv.imdecode(encoded,cv.IMREAD_UNCHANGED);np.testing.assert_array_equal(decoded,image)
                    return True
                check('opencv_png_encode_decode',image_roundtrip)
                def video_roundtrip():
                    path=directory/'ffv1.mkv';frames=[np.roll(image,i,axis=1) for i in range(6)]
                    writer=cv.VideoWriter(str(path),cv.CAP_FFMPEG,cv.VideoWriter_fourcc(*'FFV1'),12.0,(64,48),True)
                    try:
                        assert writer.isOpened() and writer.getBackendName()=='FFMPEG'
                        for frame in frames:writer.write(frame)
                    finally:writer.release()
                    capture=cv.VideoCapture(str(path),cv.CAP_FFMPEG)
                    try:
                        assert capture.isOpened() and capture.getBackendName()=='FFMPEG'
                        for expected in frames:
                            ok,frame=capture.read();assert ok;np.testing.assert_array_equal(frame,expected)
                        ok,_=capture.read();assert not ok
                    finally:capture.release()
                    return True
                check('opencv_ffv1_ffmpeg_write_read_exact',video_roundtrip)
        for sample in samples:
            path=Path(sample).resolve();before=file_hash(path)
            def read_sample(path=path):
                h5=modules['h5py'];datasets=[]
                with h5.File(path,'r') as f:
                    def visit(name,obj):
                        if isinstance(obj,h5.Dataset):
                            selection=tuple(slice(0,min(2,n)) for n in obj.shape)
                            obj[selection] if obj.shape else obj[()]
                            datasets.append({'name':name,'shape':list(obj.shape),'dtype':str(obj.dtype),'compression':obj.compression})
                    f.visititems(visit)
                    if f.attrs.get('scientific_python_fixture',False):
                        np=modules['numpy']
                        np.testing.assert_array_equal(f['values'][...],np.arange(60,dtype=np.float64).reshape(3,4,5)/8)
                        assert f['values'].compression=='gzip' and f['values'].attrs['units']=='test-unit'
                return datasets
            datasets=check('read_sample_'+path.name,read_sample)
            unchanged=file_hash(path)==before
            check('sample_unchanged_'+path.name,lambda unchanged=unchanged:unchanged)
            result['samples'].append({'file':path.name,'sha256':before,'unchanged':unchanged,'datasets':datasets})
    result['temporary_files_removed']=not directory.exists()
    check('temporary_file_cleanup',lambda:result['temporary_files_removed'])
    result['compatibility_limit']='Sample reads cover their actual datatypes, filters and layouts only; they do not prove support for every HDF5 2.x file feature.'
    result['success']=all(c['status']=='PASS' for c in result['checks'].values())
    return result

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prefix',default=sys.prefix)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--temp-root',type=Path)
    parser.add_argument('--sample-hdf5',type=Path,action='append',default=[])
    parser.add_argument('--expected-opencv',default='5.1.0')
    parser.add_argument('--expected-hdf5',default='1.14.6')
    args=parser.parse_args()
    result=acceptance(args.prefix,args.expected_opencv,args.expected_hdf5,args.temp_root,args.sample_hdf5)
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(result,indent=2),encoding='utf-8')
    print(json.dumps({'success':result['success'],'checks':len(result['checks']),'failed':[n for n,c in result['checks'].items() if c['status']!='PASS'],'report':str(args.output)},indent=2))
    return 0 if result['success'] else 1

if __name__=='__main__':raise SystemExit(main())
