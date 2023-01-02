#include<stdio.h>
#include<stdlib.h>
#include<math.h>

#define min(A,B) (( A < B ) ? A : B)
#define max(A,B) (( A > B ) ? A : B)
#define PI 3.1415926535897932


double hb_fun(double),hs_fun(double);
double Interpolate(double, int, double *, double *);

double *xdata,*hbdata,*hsdata,ndata;

double H=500,Hf=500;


int main(int argc,char *argv[]){

  FILE *fichero,*ficheronew;
  int nm,i,particiones,par;
  int basurai,*uno,*dos;
  double basuraf,*x,*y,*z,zz,hb,hs;
  char name[100],namenew[100],command[100];

  //
  //First We read the data from RooseveltTline.in
  //
  ////////////////////////////////////////////////////////////////////////
  //get ndata, number of data points in RooseveltTline.in
  //if((fichero=fopen("RooseveltTline.in","r"))==NULL){
  //  printf("No se puede leer RooseveltTline.in\n");
  //  exit(-1);
  //}


  // JK - this is my version which attempts to use the newly generated topography
  if((fichero=fopen("Korff_bed_surface_profile.in","r"))==NULL){
    printf("Can't load this topo file1\n");
    exit(-1);
  }

  ndata=0;
  while(fscanf(fichero,"%lg %lg %lg",&basuraf,&basuraf,&basuraf)!=EOF){
    ndata++;
  }
  fclose(fichero);

  //Allocate pointers 
  xdata=(double *)calloc(ndata,sizeof(double));
  hsdata=(double *)calloc(ndata,sizeof(double));
  hbdata=(double *)calloc(ndata,sizeof(double));
  
  //Now get the data, number of data points in RooseveltTline.in
  // if((fichero=fopen("RooseveltTline.in","r"))==NULL){
  //  printf("No se puede leer RooseveltTline.in\n");
  //  exit(-1);
  //}

  if((fichero=fopen("Korff_bed_surface_profile.in","r"))==NULL){
    printf("Can't load this topo file2\n");
    exit(-1);
  }

      
  for(i=0;i<ndata;i++){
    fscanf(fichero,"%lg %lg %lg",&xdata[i],&hbdata[i],&hsdata[i]);
    //    printf("%lg %lg %lg\n",xdata[i],hbdata[i],hsdata[i]);
  }
  fclose(fichero);
  /////////////////////////////////////////////////////////////////////////

  if(argc!=2){
    printf("Esta version del programa requiere el numero de particiones. Adios!\n");
    exit(-1);
  }

  particiones=atoi(argv[1]);


  if(particiones>1){
 
    nm=0;
    for(par=0;par<particiones;par++){
      sprintf(name,"mesh/partitioning.%d/part.%d.nodes",particiones,par+1);
      if((fichero=fopen(name,"r"))==NULL){
	printf("No se puede leer %s (0)\n",name);
	exit(-1);
      }
      while(fscanf(fichero,"%d %d %lg %lg %lg",&basurai,&basurai,&basuraf,&basuraf,&basuraf)!=EOF){
	nm++;
      }
      fclose(fichero);
    }


    uno=(int *)calloc(nm,sizeof(int));
    dos=(int *)calloc(nm,sizeof(int));
    x=(double *)calloc(nm,sizeof(double));
    y=(double *)calloc(nm,sizeof(double));
    z=(double *)calloc(nm,sizeof(double));

    for(i=0,par=0;par<particiones;par++){
      sprintf(name,"mesh/partitioning.%d/part.%d.nodes",particiones,par+1);
      sprintf(namenew,"mesh/partitioning.%d/part.%d.nodes_new",particiones,par+1);
      if((fichero=fopen(name,"r"))==NULL){
	printf("No se puede leer %s\n",name);
	exit(-1);
      }
      if((ficheronew=fopen(namenew,"w"))==NULL){
	printf("No se puede escribir %s\n",namenew);
	exit(-1);
      }
      while(fscanf(fichero,"%d %d %lg %lg %lg",&uno[i],&dos[i],&x[i],&y[i],&z[i])!=EOF){     


	hb=hb_fun(x[i]);
	hs=hs_fun(x[i]);
	y[i]=(1.0-y[i]/H)*hb+(y[i]/H)*hs;

	fprintf(ficheronew,"%d %d %lg %lg %lg\n",uno[i],dos[i],x[i],y[i],z[i]);
	i++;
      }
      fclose(fichero);
      fclose(ficheronew);
    
      sprintf(command,"mv %s %s",namenew,name);
      system(command);
    }

  }
  else{

   if((fichero=fopen("mesh/mesh.nodes","r"))==NULL){
      printf("No se puede leer mesh.nodes\n");
      exit(-1);
    }
 
    nm=0;
    while(fscanf(fichero,"%d %d %lg %lg %lg",&basurai,&basurai,&basuraf,&basuraf,&basuraf)!=EOF){
      nm++;
    }

    fclose(fichero);

    uno=(int *)calloc(nm,sizeof(int));
    dos=(int *)calloc(nm,sizeof(int));
    x=(double *)calloc(nm,sizeof(double));
    y=(double *)calloc(nm,sizeof(double));
    z=(double *)calloc(nm,sizeof(double));

    if((fichero=fopen("mesh/mesh.nodes","r"))==NULL){
      printf("No se puede leer mesh.nodes\n");
      exit(-1);
    }

    for(i=0;i<nm;i++){
      fscanf(fichero,"%d %d %lg %lg %lg",&uno[i],&dos[i],&x[i],&y[i],&z[i]);
    }
    fclose(fichero);


    if((fichero=fopen("mesh/mesh.nodes","w"))==NULL){
      printf("No se puede escribir mesh.nodes\n");
      exit(-1);
    }
    
    for(i=0;i<nm;i++){

      hb=hb_fun(x[i]);
      hs=hs_fun(x[i]);
      y[i]=(1.0-y[i]/H)*hb+(y[i]/H)*hs;
      
      fprintf(fichero,"%d %d %lg %lg %lg\n",uno[i],dos[i],x[i],y[i],z[i]);
    }
    fclose(fichero);
  }
  return 0;
};


double hs_fun(double xx)
{ 
 // return(hb_fun(xx)+Hf); // uncomment this line and comment the line below if you do not want to define an initial surface (surface defined by thickness)
  return(Interpolate(xx,ndata,xdata,hsdata));   // uncomment this line and comment the line above if I want to define an intial surface. I will have to define the surface in the third column of the data array used by this program (at the moment it is called: RooseveltLineModified.in).
};

double hb_fun(double xx)
{
  return(Interpolate(xx,ndata,xdata,hbdata));
};

double Interpolate(double xi,int nn,double *xx,double *yy)
{
  double yi=-6;
  int i;
  
  if(xi>=xx[nn-1])
    yi=yy[nn-1];
  else if (xi<=xx[0])
    yi=yy[0];
  else{
    for(i=0;i<nn-1;i++){
      if(xi>=xx[i]&&xi<=xx[i+1]){
	yi=yy[i]+(yy[i+1]-yy[i])*(xi-xx[i])/(xx[i+1]-xx[i]);
	break;
      }
    }
  }
  
  return(yi);
};
