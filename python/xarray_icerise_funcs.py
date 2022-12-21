import numpy as np
import matplotlib.pyplot as plt 
import xarray as xr
import meshio
import gcsfs

def vtu_transform(projname,bucket):
    """

    Input: 
        projname = Google Cloud project name (standard
        bucket = Google Cloud Bucket path with vtu files (i.e. 'ldeo-glaciology/elmer_janie/run_outputs/run_accum_0.2_1000/'
    Output:
    datacomb - xarray dataset with dimensions (t,ynode,xnode) and coordinates (xvals, yvals),
               Data vars - (vel_x,vel_y)

    NOTE: sometimes gives warnings about Compute Engine Metadata - this does not affect loading the data 
    """
    #projname = 'ldeo-glaciology'
    #bucket = 'ldeo-glaciology/elmer_janie/output_vals/'

    fs = gcsfs.GCSFileSystem(project=projname)
    filelist = fs.ls(bucket)


    #info about mesh grid (set by user in model - mesh.grd file in bucket)
    xgrid_cells = 1000
    ygrid_cells = 30

    xgrid_pts = xgrid_cells + 1
    ygrid_pts = ygrid_cells + 1

    xnodes = np.array(range(xgrid_pts)) #ynodes 
    ynodes = np.array(range(ygrid_pts))  # xnodes
    tsteps = np.array(range(len(filelist)))  #number of time steps

    timestep = [] #list of data arrays
    for path in filelist:
        t_val = filelist.index(path)
        print(path)
        #print(t_val)
        gcs_file = fs.get(path,'out.vtu') #load file
        mesh = meshio.read('out.vtu', file_format= 'vtu') #mesh the file

        velx = mesh.point_data['velocity'][:,0].reshape((ygrid_pts,xgrid_pts)) #reshape the mesh coordinates
        vely = mesh.point_data['velocity'][:,1].reshape((ygrid_pts,xgrid_pts))

        xdim = mesh.points[:,0].reshape((ygrid_pts,xgrid_pts))
        ydim = mesh.points[:,1].reshape((ygrid_pts,xgrid_pts))

        tempdataset = xr.Dataset(data_vars = {'vel_x' : (('ynode','xnode'), velx) ,'vel_y' :(('ynode','xnode'), vely)},
                          coords = {'yvals': (('ynode','xnode'),ydim),'xvals': (('ynode','xnode'),xdim)})
        timestep.append(tempdataset)

    datacomb = xr.concat(timestep, dim='t')
    return datacomb

def surface_deriv(datacomb):
    """
    Input:
    datacomb - xarray dataset with dimensions (t,ynode,xnode) and coordinates (xvals, yvals),
               Data vars - (vel_x,vel_y)

    Output:
    surfder - xarray dataset with dimensions (t,xnode) and coordinates (xvals, years), 
              Data vars - (yvals,dy,dy2)

    """
    surface = datacomb.yvals.sel(ynode = (datacomb.ynode.shape[0] - 1))

    dx = (surface.xvals[0,1] - surface.xvals[0,0]).item()
    dysurf = np.zeros(surface.shape)
    dy2surf = np.zeros(surface.shape)
    #calculate derivatives of profiles in each time step 
    for w in range(len(surface.t)):
        dysurf[w,1:] = (surface.sel(t = w)[1:] - surface.sel(t = w)[0:-1])/dx
        dy2surf[w,1:-1] = (surface.sel(t = w)[0:-2] - 2*surface.sel(t = w)[1:-1] + surface.sel(t = w)[2:])/(dx**2)

    #create dataset from derivatives
    der = xr.Dataset(data_vars = {'dy' : (('t','xnode'), dysurf), 
                                 'dy2' : (('t','xnode'), dy2surf)})

    #merge derivatives dataset with surface dataset 
    surfder = xr.merge([surface.drop('yvals'),der])
    return surfder