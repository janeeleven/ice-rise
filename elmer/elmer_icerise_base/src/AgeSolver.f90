SUBROUTINE AgeSolver( Model,Solver,dt,TransientSimulation )
  !------------------------------------------------------------------------------
  !******************************************************************************
  !  Calculate Age. SemiLagrangian Method
  !
  !  New Notes:
  !    - New ALE formulation. To be used when remeshing.
  !
  !
  !  More notes for Thomas:
  !  - New parallel code that doesn't need halos in the partitions. The partitions request the Age from the nodes 
  !    it could not track from neighbours. We should think about not using this when there are halos
  !     as it is redundant but at the moment it does do it always.  
  !  - Included a new BC .  Horizontal gradient of age is null in the BC. That equals to ignore the horizontal 
  !     components of velocity. It should be only the normal component but I will code that later.  It is activated with:
  !                              AgeIn= Logical True
  !
  !  Notes for Thomas:
  !  - As far as I know, the solver is working in 2D and 3D, serial and parallel
  !  - I haven't implemented the iterative search of departure points (or being positive, number of iterations = 1)
  !    I doesn't make any difference with ice flow  but it should be include in case there are strong gradients of Velocity
  !    with more general problems. I'll do it soon.
  ! -  For every node it does look for the particle position on the previous time step that it is on the node at current time.
  !    It does only look in the surounding elements. If the particle is outside this elements, solver is lost and timestep
  !    has to be adjusted manually.
  ! -  It does only work for  '>Flow Solution Name< not found in section >Equation<' and it should have DOFs = DIM + 1  
  !    and not for constant convection squemes. I could improve that easyly but please go ahead if you feel we need it.
  ! -  Once it knows the nodal solution I use a dirty trick to make it work in parallel and that is to solve the identity matrix I. 
  !    That is I Age = Agei, where I is the identity matrix, Age is the vector of unknowns and Agei is the nodal solution
  !    found by the solver. The system is quite easy and it is solved quick with:
  !                     Linear System Iterative Method = Diagonal
  !                     Linear System Preconditioning = None
  !
  !  Notes: 
  !  Reference to Martin and Gudmundsson (2012), Effects on nonlinear rheology and anisotropy on the
  !  relationship between age and depth at ice divides, submitted to TCD, would be appreciated.  
  !
  !  Numerical details:
  !  This solver implement a semilagrangian algoritm with a two-time-level scheme and linear interpolation. 
  !  It is based in Staniforth, Andrew, Jean C??t??, 1991: Semi-Lagrangian Integration Schemes for Atmospheric 
  !  Models???A Review. Mon. Wea. Rev., 119, 2206???2223.
  !******************************************************************************
  USE DefUtils


  IMPLICIT NONE
  !------------------------------------------------------------------------------
  TYPE(Solver_t) :: Solver
  TYPE(Model_t) :: Model

  REAL(KIND=dp) :: dt
  LOGICAL :: TransientSimulation
  !------------------------------------------------------------------------------
  ! Local variables
  !------------------------------------------------------------------------------
  Integer :: DIM,N,e,i,j,k,kf,km,ka,kd,kd2,kk,NMax,NM,stat
  Logical :: GotIt,FirstTime=.TRUE.,IsThere,ALE

  INTEGER, POINTER :: AgePerm(:)
  REAL(KIND=dp), POINTER :: Age(:),Age0(:)

  TYPE(Element_t),POINTER :: Element
  TYPE(Nodes_t)   :: ElementNodes
  INTEGER,  POINTER ::  NodeIndexes(:)
  TYPE(Matrix_t), POINTER :: Systemmatrix

  CHARACTER(LEN=MAX_NAME_LEN) :: FlowSolName
  TYPE(Variable_t), POINTER :: FlowSol,MeshVelSol
  INTEGER, POINTER :: FlowPerm(:),MeshVelPerm(:)
  REAL(KIND=dp), POINTER :: Flow(:),MeshVel(:)
  INTEGER :: FlowDOFs,MeshVelDOFs

  INTEGER :: NNMAX
  INTEGER,  ALLOCATABLE :: NoNeigh(:),NeighList(:,:)


  REAL(KIND=dp) :: xa(3),xm(3),xd(3),alpha(3),um(3)
  REAL(KIND=dp), DIMENSION(3) :: LocalCoordinates
  REAL(KIND=dp) :: eps=1.0e-4
  INTEGER :: MaxDOFs
  REAL(KIND=dp), ALLOCATABLE :: Vector(:,:)
  REAL(KIND=dp) :: Agea

  REAL(KIND=dp) :: disp

  REAL(KIND=dp) :: at,st,totat,totst,CPUTime,Norm,PrevNorm,RelativeChange

  !Experimental
  LOGICAL, ALLOCATABLE :: Found(:),isBC(:),isAgeIn(:)
  TYPE(ValueList_t), POINTER :: BC
  REAL(KIND=dp), ALLOCATABLE :: Cond(:)

  INTEGER :: nn,precv
  INTEGER, POINTER :: nlist(:)

  INTEGER :: ierr,gk
  INTEGER :: request(ParEnv % PEs)
  TYPE buffer_t
     INTEGER :: n
     INTEGER, ALLOCATABLE :: gbuff(:)
     REAL(KIND=dp), ALLOCATABLE :: vbuff(:)
  END TYPE buffer_t
  TYPE(buffer_t) :: RequestSend(ParEnv % PEs),RequestRecv(ParEnv % PEs)
  TYPE(buffer_t) :: ReplySend(ParEnv % PEs),ReplyRecv(ParEnv % PEs)



  SAVE FirstTime,NoNeigh,NeighList,Found,isBC,isAgeIn

  WRITE(Message,'(a)') 'Start Solver'
  CALL Info('AgeSolver', Message, Level=4)

  !------------------------------------------------------------------------------
  ! Get Constants
  !------------------------------------------------------------------------------

  DIM = CoordinateSystemDimension()
  NMAX = Model % MaxElementNodes
  NM = Solver % Mesh % NumberOfNodes

  IF(DIM==2) THEN
     NNMAX = 10!4
  ELSE
     NNMAX=20!8
  END IF

  MaxDOFs=DIM

  !------------------------------------------------------------------------------
  !    Get variables for the solution
  !------------------------------------------------------------------------------

  Age     => Solver % Variable % Values     ! Nodal values for 
  AgePerm => Solver % Variable % Perm       ! Permutations for 
  Age0 => Solver % Variable % PrevValues(:,1)

  FlowSolName =  GetString( GetEquation(Solver % Mesh % Elements(1)),'Flow Solution Name', GotIt)
  IF(.NOT.GotIt) THEN        
     CALL WARN('AgeSolver','Keyword >Flow Solution Name< not found in section >Equation<')
     CALL WARN('AgeSolver','Taking default value >Flow Solution<')
     WRITE(FlowSolName,'(A)') 'Flow Solution'
  END IF
  FlowSol => VariableGet( Solver % Mesh % Variables, FlowSolName )
  IF ( ASSOCIATED( FlowSol ) ) THEN
     FlowPerm     => FlowSol % Perm
     FlowDOFs     =  FlowSol % DOFs
     Flow               => FlowSol % Values
  ELSE
     WRITE(Message,'(A,A,A)') &
          'Convection flag set to >computed<, but no variable >',FlowSolName,'< found'
     CALL FATAL('AgeSolver',Message)              
  END IF

  ! Check if the mesh is moving, if so activate the ALE formulation for the velocity
  MeshVelSol => VariableGet( Solver % Mesh % Variables, "mesh velocity")
  IF ( ASSOCIATED( MeshVelSol ) ) THEN
     ALE = .TRUE.
     CALL INFO( 'AgeSolver', 'ALE formualtion activated', Level=4 )
     MeshVelPerm     => MeshVelSol % Perm
     MeshVelDOFs     =   MeshVelSol % DOFs
     MeshVel               => MeshVelSol % Values
  ELSE
     ALE = .FALSE.
     CALL INFO( 'AgeSolver', 'ALE formualtion NOT activated', Level=4 )
  END IF

  !------------------------------------------------------------------------------
  !    Inicialization
  !-----------------------------------------------------------------------------



  ALLOCATE( ElementNodes % x( NMAX ),      &
       ElementNodes % y( NMAX ),      &
       ElementNodes % z( NMAX ),      &
       Vector(MaxDOFS,NMAX),                  &
       STAT=stat  )
  IF ( stat /= 0 ) THEN
     CALL Fatal('AgeSolver','Memory allocation error, Aborting.')
  END IF

  IF(FirstTime) THEN
     ALLOCATE( NoNeigh(NM),&
          Neighlist(NM,NNMAX),&
          Found(NM),                  &
          Cond(NMAX),                  &
          STAT=stat  )
     IF ( stat /= 0 ) THEN
        CALL Fatal('AgeSolver','Memory allocation error, Aborting.')
     END IF


     NoNeigh=0
     DO e=1,Solver % NumberOfActiveElements
        Element => GetActiveElement(e)
        n = GetElementNOFNodes()
        NodeIndexes => Element % NodeIndexes

        DO i=1,n
           k=NodeIndexes(i)

           IF(NoNeigh(k)==0) THEN
              NoNeigh(k)=1
              NeighList(k,1)=e
           ELSE
              IsThere=.FALSE.
              DO j=1,NoNeigh(k)
                 IF(NeighList(k,j)==e) THEN
                    IsThere=.TRUE.
                    EXIT
                 END IF
              END DO

              IF(.NOT.IsThere) THEN
                 NoNeigh(k)= NoNeigh(k) + 1
                 NeighList(k, NoNeigh(k))=e                 
              END IF
           END IF
        END DO

     END DO

     ! Flag nodes that are in BC with AgeIn. 
     !(We will assume that the horizontal gradient of age is null and ignore the horizontal components of velocity.) 
     ALLOCATE(isAgeIn(NM),                  &
          STAT=stat  )
     IF ( stat /= 0 ) THEN
        CALL Fatal('AgeSolver','Memory allocation error, Aborting.')
     END IF
     isAgeIn=.FALSE.
     DO i=1,GetNofBoundaryElements()
        Element=>GetBoundaryElement(i)
        n = GetElementNOFNodes()
        NodeIndexes => Element % NodeIndexes
        BC=>GetBC()
        IF(.NOT.ASSOCIATED(BC)) CYCLE

        IF(ListCheckPresent(BC,'AgeIn'))  THEN

           DO j=1,Model % NumberOfBCs
              IF ( Element % BoundaryInfo % Constraint == Model % BCs(j) % Tag ) THEN                  
                 !                print *,ListGetLogical(Model % BCs(j) % Values,'AgeIn', gotIt )
                 isAgeIn(Nodeindexes)= &
                      ListGetLogical(Model % BCs(j) % Values,'AgeIn', gotIt )
              END IF
           END DO

        END IF

     END DO




     IF(ParEnv % PEs>1) THEN


        ! Flag nodes that are Dirichlet Boundary conditions

        ALLOCATE(isBC(NM),                  &
             STAT=stat  )
        IF ( stat /= 0 ) THEN
           CALL Fatal('AgeSolver','Memory allocation error, Aborting.')
        END IF


        ! Check if the node has Dirichlet BC, in that case we will ignore
        isBC=.FALSE.
        DO i=1,GetNofBoundaryElements()
           Element=>GetBoundaryElement(i)
           n = GetElementNOFNodes()
           NodeIndexes => Element % NodeIndexes
           BC=>GetBC()
           IF(.NOT.ASSOCIATED(BC)) CYCLE

           IF(ListCheckPresent(BC,Solver % Variable % Name))  THEN

              ! Check first if we are using Age Condition = -1
              IF(ListCheckPresent(BC,Trim(Solver % Variable % Name)//' Condition'))  THEN

                 DO j=1,Model % NumberOfBCs
                    IF ( Element % BoundaryInfo % Constraint == Model % BCs(j) % Tag ) THEN                  
                       isBC(Nodeindexes)= &
                            (ListGetReal(Model % BCs(j) % Values,&
                            Trim(Solver % Variable % Name)//' Condition',n, NodeIndexes, gotIt )>=0.0d0)   
                    END IF
                 END DO
              ELSE
                 isBC(Nodeindexes)=.TRUE.
              END IF

           END IF

        END DO
     END IF

  END IF

  SystemMatrix => Solver % Matrix

  totat = 0.0_dp
  totst = 0.0_dp
  at = CPUTime()
  CALL INFO( 'AgeSolver', 'start assembly', Level=4 )

  CALL DefaultInitialize()
  CALL DefaultFinishAssembly()

  Norm=0.0d0

  DO k=1,NM
     ka=AgePerm(k)
     kf=FlowPerm(k)
     km=MeshVelPerm(k)

     xa(1) = Solver % Mesh % Nodes % x(k)
     xa(2) = Solver % Mesh % Nodes % y(k)
     xa(3) = Solver % Mesh % Nodes % z(k) 

     IF(ALE) THEN
        IF(DIM==2.AND.FlowDOFs==3) THEN
           alpha(1)=Dt*(Flow(FlowDOFs*kf-2)-MeshVel(MeshVelDOFs*km-1))
           alpha(2)=Dt*(Flow(FlowDOFs*kf-1)-MeshVel(MeshVelDOFs*km))
           alpha(3)=0._dp
        ELSE IF(DIM==3.AND.FlowDOFs==4) THEN
           alpha(1)=Dt*Flow(FlowDOFs*kf-3)
           alpha(2)=Dt*Flow(FlowDOFs*kf-2)
           alpha(3)=Dt*Flow(FlowDOFs*kf-1)
        ELSE
           CALL Fatal('AgeSolver','DIM AND FlowDOFS do not combine.  Aborting.')
        END IF
     ELSE
        IF(DIM==2.AND.FlowDOFs==3) THEN
           alpha(1)=Dt*Flow(FlowDOFs*kf-2)
           alpha(2)=Dt*Flow(FlowDOFs*kf-1)
           alpha(3)=0._dp
        ELSE IF(DIM==3.AND.FlowDOFs==4) THEN
           alpha(1)=Dt*Flow(FlowDOFs*kf-3)
           alpha(2)=Dt*Flow(FlowDOFs*kf-2)
           alpha(3)=Dt*Flow(FlowDOFs*kf-1)
        ELSE
           CALL Fatal('AgeSolver','DIM AND FlowDOFS do not combine.  Aborting.')
        END IF
     END IF

     IF(isAgeIn(k)) THEN
        DO j=1,DIM-1
           alpha(j)=0.0d0
        END DO
     END IF

     xm(1:3)=xa(1:3)-alpha(1:3)/2._dp


     Found(k)=.FALSE.  
     IsThere=.FALSE.
     DO i=1,NoNeigh(k)
        e=NeighList(k,i)
        Element => Solver % Mesh % Elements(e)

        n = Element % Type % NumberOfNodes
        NodeIndexes => Element % NodeIndexes

        ElementNodes % x(1:n) = Solver % Mesh % Nodes % x(NodeIndexes)
        ElementNodes % y(1:n) = Solver % Mesh % Nodes % y(NodeIndexes)
        ElementNodes % z(1:n) = Solver % Mesh % Nodes % z(NodeIndexes)

        IF ( PointInElement( Element, ElementNodes, xm, LocalCoordinates,NumericEps=eps) )  THEN
           IsThere=.TRUE.
           EXIT
        END IF
     END DO

     IF ( IsThere) THEN

        DO j=1,DIM
           IF(ALE) THEN
              Vector(j,1:n)=Flow(FlowDOFs*(FlowPerm(NodeIndexes)-1)+j)&
                   -MeshVel(MeshVelDOFs*(MeshVelPerm(NodeIndexes)-1)+j)
           ELSE
              Vector(j,1:n)=Flow(FlowDOFs*(FlowPerm(NodeIndexes)-1)+j)
           END IF
        END DO

        IF(isAgeIn(k)) THEN
           DO j=1,DIM-1
              Vector(j,1:n)=0.0d0
           END DO
        END IF


        um=0.0d0
        DO j=1,DIM
           um(j)=InterpolateInElement(Element,Vector(j,1:n),&
                LocalCoordinates(1),LocalCoordinates(2), LocalCoordinates(3))
        END DO

        alpha(1)=Dt*um(1)
        alpha(2)=Dt*um(2)
        alpha(3)=Dt*um(3)           

        xd(1)=xa(1)-alpha(1)
        xd(2)=xa(2)-alpha(2)
        xd(3)=xa(3)-alpha(3)

        IsThere=.FALSE.
        DO i=1,NoNeigh(k)
           e=NeighList(k,i)
           Element => Solver % Mesh % Elements(e)

           n = Element % Type % NumberOfNodes
           NodeIndexes => Element % NodeIndexes

           ElementNodes % x(1:n) = Solver % Mesh % Nodes % x(NodeIndexes)
           ElementNodes % y(1:n) = Solver % Mesh % Nodes % y(NodeIndexes)
           ElementNodes % z(1:n) = Solver % Mesh % Nodes % z(NodeIndexes)

           IF ( PointInElement( Element, ElementNodes, xd, LocalCoordinates,NumericEps=eps) )  THEN
              IsThere=.TRUE.
              EXIT
           END IF
        END DO

        IF ( IsThere) THEN

!!!! Should be the solution in the previous time-step Age0 but let's do it this way for now
           Vector(1,1:n)=Age(AgePerm(Element % NodeIndexes))     

           Agea=InterpolateInElement(Element,Vector(1,1:n), LocalCoordinates(1), &
                LocalCoordinates(2), LocalCoordinates(3) )+Dt

           Found(k)=.TRUE.
           CALL SetMatrixElement( SystemMatrix, ka, ka, 1.0d0 ) 
           SystemMatrix % RHS(ka) = Agea
!!$        Age(AgePerm(k))=Agea
!!$        Norm=max(Norm,ABS(Age(AgePerm(k))-Age0(AgePerm(k))))



        END IF

     END IF

  END DO



!!! In parallel, look for the lost ones
  IF (ParEnv % PES >1) THEN

     ! Calculate number of nodes we haven't found in this partition and where could they be.
     RequestSend(1:ParEnv % PES)  % n = 0
     DO k=1,NM
        ! WE NEED NODE K if
        IF(Solver % Mesh % ParallelInfo % INTERFACE(k).AND.(.NOT.Found(k)).AND.(.NOT.isBC(k)))  THEN

           nlist => Solver % Mesh % ParallelInfo % NeighbourList(k) % Neighbours
           nn=SIZE(Solver % Mesh % ParallelInfo % NeighbourList(k) % Neighbours)
           DO i=1,nn
              precv=nlist(i)
              IF(precv==ParEnv % MyPE) CYCLE
              RequestSend(precv+1)  % n = RequestSend(precv+1)  % n + 1
           END DO
        END IF
     END DO

     !Now get serious and store all the info needed to send a request
     ! Allocate space
     DO i=1,ParEnv % PEs
        ALLOCATE(RequestSend(i) % gbuff( RequestSend(i)  % n))
     END DO
     ! And again but now storing data
     RequestSend(1:ParEnv % PES)  % n = 0
     DO k=1,NM     
        ! WE NEED NODE K if
        IF(Solver % Mesh % ParallelInfo % INTERFACE(k).AND.(.NOT.Found(k)).AND.(.NOT.isBC(k)))  THEN
           nlist => Solver % Mesh % ParallelInfo % NeighbourList(k) % Neighbours
           nn=SIZE(Solver % Mesh % ParallelInfo % NeighbourList(k) % Neighbours)
           DO i=1,nn
              precv=nlist(i)
              IF(precv==ParEnv % MyPE) CYCLE
              RequestSend(precv+1)  % n = RequestSend(precv+1)  % n + 1
              RequestSend(precv+1)  % gbuff(RequestSend(precv+1)  % n)=Solver % Mesh % ParallelInfo % GlobalDOFs(k)
           END DO
        END IF
     END DO
!!$
!!$     !Send number of requested nodes to partitions. They are RequestRecv in the other end
     DO i=1,ParEnv % PEs
        CALL MPI_iRECV(RequestRecv(i) % n, 1, MPI_INTEGER,i-1, 910, MPI_COMM_WORLD,request(i),ierr )       
     END DO

     DO i=1,ParEnv % PEs
        CALL MPI_BSEND(RequestSend(i) % n, 1, MPI_INTEGER,i-1, 910, MPI_COMM_WORLD,ierr)
     END DO

     CALL MPI_WaitAll( ParEnv % PEs,Request, MPI_STATUSES_IGNORE, ierr )
!!$
     !Allocate space for requested nodes from partition i-1 to this partition
     DO i=1,ParEnv % PEs
        ALLOCATE(RequestRecv(i) % gbuff( RequestRecv(i)  % n))
     END DO

     !Send global DOF of the requested nodes across
     DO i=1,ParEnv % PEs
        CALL MPI_iRECV(RequestRecv(i) % gbuff,RequestRecv(i)  % n, &
             MPI_INTEGER,i-1, 910, MPI_COMM_WORLD,request(i),ierr )       
     END DO

     DO i=1,ParEnv % PEs
        CALL MPI_BSEND(RequestSend(i) % gbuff,RequestSend(i)  % n, &
             MPI_INTEGER,i-1, 910, MPI_COMM_WORLD,ierr)
     END DO

     CALL MPI_WaitAll( ParEnv % PEs,Request, MPI_STATUSES_IGNORE, ierr )

     ! Now comes the big question. Do we have that info in this partition?     
     DO i=1,ParEnv % PEs
        !(I'm going to be optimistic in the space allocated)
        ALLOCATE(ReplySend(i) % vbuff(RequestRecv(i)  % n),ReplySend(i) % gbuff(RequestRecv(i)  % n))
        ReplySend(i) % n = 0
        DO j=1,RequestRecv(i) % n
           gk = RequestRecv(i) % gbuff(j)
           k=SearchNode( SystemMatrix % ParallelInfo,gk,Order= SystemMatrix % Perm)
           IF(k<0) CYCLE
           IF(Found(k)) THEN
              ReplySend(i) % n = ReplySend(i) % n + 1
              ReplySend(i) % vbuff(ReplySend(i) % n)=SystemMatrix % RHS(AgePerm(k))
              ReplySend(i) % gbuff(ReplySend(i) % n)=gk
           ELSE
              !Warning should be a bit more precisse than this, it could be in a third partition.
!!$              IF(SIZE(Solver % Mesh % ParallelInfo % NeighbourList(k) % Neighbours)==2) THEN
!!$                 PRINT *,'Could not find node',gk,k,' For partition' ,i-1
!!$              END IF
           END IF
        END DO
     END DO

     !Send number of Replies to partitions. They are ReplyRecv in the other end
     DO i=1,ParEnv % PEs
        CALL MPI_iRECV(ReplyRecv(i) % n, 1, MPI_INTEGER,i-1, 910, MPI_COMM_WORLD,request(i),ierr )       
     END DO

     DO i=1,ParEnv % PEs
        CALL MPI_BSEND(ReplySend(i) % n, 1, MPI_INTEGER,i-1, 910, MPI_COMM_WORLD,ierr)
     END DO

     CALL MPI_WaitAll( ParEnv % PEs,Request, MPI_STATUSES_IGNORE, ierr )

     !Send the global DOF of the found nodes
     DO i=1,ParEnv % PEs
        ALLOCATE(ReplyRecv(i) % gbuff(ReplyRecv(i)  % n))
        CALL MPI_iRECV(ReplyRecv(i) % gbuff,ReplyRecv(i)  % n, &
             MPI_INTEGER,i-1, 910, MPI_COMM_WORLD,request(i),ierr )       
     END DO

     DO i=1,ParEnv % PEs
        CALL MPI_BSEND(ReplySend(i) % gbuff,ReplySend(i)  % n, &
             MPI_INTEGER,i-1, 910, MPI_COMM_WORLD,ierr)
     END DO

     CALL MPI_WaitAll( ParEnv % PEs,request, MPI_STATUSES_IGNORE, ierr )

     !Send the Age values of the requested nodes
     DO i=1,ParEnv % PEs
        ALLOCATE(ReplyRecv(i) % vbuff(ReplyRecv(i)  % n))
        CALL MPI_iRECV(ReplyRecv(i) % vbuff,ReplyRecv(i)  % n, &
             MPI_DOUBLE_PRECISION,i-1, 910, MPI_COMM_WORLD,request(i),ierr )
     END DO

     DO i=1,ParEnv % PEs
        CALL MPI_BSEND(ReplySend(i) % vbuff,ReplySend(i)  % n, &
             MPI_DOUBLE_PRECISION,i-1, 910, MPI_COMM_WORLD,ierr)
     END DO

     CALL MPI_WaitAll( ParEnv % PEs,request, MPI_STATUSES_IGNORE, ierr )

     !Finally make it happen!
     DO i=1,ParEnv % PEs
        DO j=1,ReplyRecv(i)  % n
           gk=ReplyRecv(i) % gbuff(j)
           k=SearchNode( SystemMatrix % ParallelInfo,gk,Order= SystemMatrix % Perm)
           IF(k<0) CYCLE
           ka=AgePerm(k)
           Agea=ReplyRecv(i) % vbuff(j)

           CALL SetMatrixElement( SystemMatrix, ka, ka, 1.0d0 ) 
           SystemMatrix % RHS(ka) = Agea

           !           Age(ka)=Agea
        END DO
     END DO
  END IF



  CALL DefaultDirichletBCs()

  !------------------------------------------------------------------------------
  !    Solve System  and check for convergence
  !------------------------------------------------------------------------------
  at = CPUTime() - at
  st = CPUTime() 

  PrevNorm = Solver % Variable % Norm

  Norm = DefaultSolve()

  IF ( PrevNorm + Norm /= 0.0_dp ) THEN
     RelativeChange = 2.0_dp * ABS( PrevNorm-Norm ) / (PrevNorm + Norm)
  ELSE
     RelativeChange = 0.0_dp
  END IF

  WRITE( Message, * ) 'Result Norm   : ',Norm
  CALL INFO( 'AgeSolver', Message, Level=4 )
  WRITE( Message, * ) 'Relative Change : ',RelativeChange
  CALL INFO( 'AgeSolver', Message, Level=4 )




  FirstTime=.FALSE.


END SUBROUTINE AgeSolver


