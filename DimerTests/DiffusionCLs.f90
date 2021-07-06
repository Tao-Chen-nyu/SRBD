module DiffusionCLs
    use Precision
    use BoxLibRNGs
    use, intrinsic :: iso_fortran_env, only: stderr => error_unit       ! This is so I can track errors.
    implicit none 
    save

    integer, parameter                              :: wp = r_sp, dim = 3       ! Note, dim should be nDimensions, but cant access from here.
    ! Donev: It is a bit strange to make kbT a parameter but give it the wrong value -- maybe make it a variable so user can set correct value?
    real(wp), parameter                             :: kbT = 1.0_wp, pi = 4.0_wp*ATAN(1.0_wp)
    ! Donev: Some of these variables should maybe be private, see below
    real(wp)                                        :: k_s, mu_1, mu_2, l0, dimensionlessTSSize, dt, a_1, a_2, visc, tau, mu_eff
    ! Donev: Variable nsteps makes no sense here -- what does it mean
    ! The number of steps taken should be an argument passed into the routines, and is controlled by the driver (the code using these routines)
    ! Variables like myunit1 should be private, as in:
    ! private :: myunit1 
    ! after you declare it. If it really needs to be public, give it a proper clear name like diffusion_cl_unit or diffusionCLUnit
    ! Think about which variables should be private here, i.e., things you only use internally but that are not used outside.
    ! One example may be mu_eff, dimensionlessTSSize
    ! Other variables that are input arguments should NOT also be module variables
    ! Use module variables only for variables that have one and only one value set globally for the whole run.
    ! Time step is something that can vary in principle (e.g., multiple routines could be using the temporal integrators here with different dt)
    ! Generally speaking, try to MINIMIZE the number of module variables (they prevent parallelization, for example, since there is one and only one copy)
    ! and especially always minimize number of public module variables
    ! There should be ONE and only one seed in the way you are using the random number stream (there is only one random stream for the whole code)
    ! This is now set in main.f90, and so there is a conflict with this seed variable
    ! I think you can assume here that the seed is set in the caller and not mess with it
    ! Another way is that we can have a separate random stream for this code, but this requires some code changes so let's not do it
    ! enum is not a good variable name, since it is too generic and unclear. Something like sde_integrator or sde_integrator_enum would be much better
    integer                                         :: nsteps, enumer, myunit1, seed
    ! Donev: add a comment here explaining what the possible values of enumer are and what they mean, e.g. =1: Euler-Maryuyama, =2: explicit midpoint
    character(len = 128)                            :: nml_file = "diffCLs.nml"
    ! Donev: Variable isOutput does not seem to be used, so delete it
    ! Donev: Default value of evolve_r_cm should be .true.
    logical, parameter                              :: isOutput = .true., evolve_r_cm = .false.



    contains 

        ! Subroutine to read in the data from a namelist file. 
        subroutine read_namelist(file_path)
            character(len=*),  intent(in)  :: file_path
            integer                        :: unit, check

            ! Namelist definition.
            ! Donev: Remove seed, dimensionlessTSSize, nsteps from here since these conflict with other variables
            ! time step should be set by caller -- it is an argument to the routines below so should not be a global variable (it can change with every call)
            ! nsteps also
            ! seed is discussed above
            namelist /diffCLs/ seed, k_s, l0, a_1, a_2, visc, dimensionlessTSSize, nsteps, enumer

            ! Check whether file exists.
            inquire (file=file_path, iostat=check)

            ! Here we have some checks, this just makes sure that the file is around. 
            if (check /= 0) then
                write (stderr, '(3a)') 'Error: The file "', trim(file_path), '" does not exist.'
                return
            end if

            ! Open and read Namelist file.
            open (action='read', file=file_path, iostat=check, newunit=unit)
            read (nml=diffCLs, iostat=check, unit=unit)

            ! This is to keep people aware of cases like : End of File runtime errors.
            if (check /= 0) then
                write (stderr, '(a)') 'Error: invalid Namelist format.'
                print *, check
            end if

            close (unit)
        end subroutine read_namelist



        ! Reads the namelist and open files and allocate arrays (we may need extra arrays to
        ! keep track of reactions ourselves)
        subroutine initializeCLs()

            ! Will read namelist and put in all values.
            ! Specifically, this reads in : seed, k_s, l0, a_1, a_2, visc, dimensionlessTSSize, nsteps, enumer
            ! Other things, like filenames to write to are not included, because this is oly needed in
            ! COM_TwoParticlesSpring.f90 and may not be used in all cases when I use this module.
            call read_namelist(nml_file)


            !Below are not in namelist since they SHOULD be defined in terms of other params in nml
            !Here I just overwrite to be 1 however, since it is nicer to work with.
            mu_1 = 1.0_wp! / (6 * pi * visc * a_1) 
            mu_2 = 1.0_wp! / (6 * pi * visc * a_2)
            mu_eff = mu_1 + mu_2
            
            ! Donev: tau should be defined in terms of mu_eff -- this is what you figured out recently was the issue with explicit midpoint stability limit
            tau = 1.0 / (mu_1 * k_s)      ! Which tau should this be, if mu is different (or should it be mu_eff)
            ! Donev: Remove
            dt = tau * dimensionlessTSSize   ! Arbitrarily chosen (this is delta t, which is a fraction of tau)

        end subroutine

        ! Implicit trapezoidal integrator as detailed in "Multiscale Temporal Integrators for Fluctuating Hydrodynamics" 
        ! Delong et. al. 
        ! Implements the scheme found in equation (33), that is where L = mu_eff * k * (l0-l12)/l12,
        ! x^{p,n+1} = x^n + dt/2 * L * (x^n + x^{p,n+1}) + sqrt(2 D dt) N_1(0,1)
        ! x^{n+1} = x^n + dt/2 * (L(x^n)x^n + L(x^n+1)x^{n+1}) + sqrt(dt 2D)N_1(0,1)
        ! Note that these are sampled from the same Normal distribution 
        ! (they will change b/w r_cm and r_d but the predictor & corrector step 
        ! seem to use the same W increment in the paper)
        subroutine implicitTrapezoidal(dt, nsteps, mu_1, mu_2, k, l0, r_cm, r_rel)
            real(wp), intent(in)                        :: dt, mu_1, mu_2, k, l0
            integer, intent(in)                         :: nsteps
            real(wp), dimension(dim), intent(inout)     :: r_cm, r_rel

            ! Local Variables
            real(wp), dimension(dim)                    :: disp1, disp2, r_cm_pred, r_rel_pred
            real(wp)                                    :: l12, sdev_cm, sdev_d, L2_n, L_n, mu_eff, D_cm, D_rel
            integer                                     :: i

            mu_eff = mu_1 + mu_2 ! Add some comments, like: Effective mobility for r_cm
            D_rel = kbT * mu_eff
            D_cm = kbT * mu_1 * mu_2 / (mu_1 + mu_2)

            ! Donev: This is implicit trapezoidal not midpoint so change the comments consistently throughout
            ! Implicit Midpoint loop
            do i = 1, nsteps
                ! Donev: Move this line inside the if(evolve_r_cm) since only used there. Same for all other routines
                ! The point of evolve_r_cm is to be more efficient if set to .false., so don't generate extra random variables
                call NormalRNGVec(numbers = disp1, n_numbers = dim) ! Mean zero and variance one
                call NormalRNGVec(numbers = disp2, n_numbers = dim) ! Mean zero and variance one

                sdev_cm = sqrt(2 * D_cm * dt)
                sdev_d = sqrt(2 * D_rel * dt)

                ! Will want to apply one Implicit Midpoint step

                ! COM STEP
                ! Donev: IMPORTANT: r_cm should always be evolved using EM regardless of how r_d is evolved
                ! So change all of these to just take one EM step
                if (evolve_r_cm) then
                    ! Donev: should just be the "corrector" step (EM) -- no need for predictor
                    ! Predictor Step
                    r_cm_pred = r_cm + sdev_cm * disp1
                    !   Corrector Step
                    r_cm = r_cm + sdev_cm * disp1
                end if

                ! R DIFFERENCE STEP. Note I think that for both predicting and correcting step in the implicit 
                ! trap method is the SAME Wiener increment, as in the paper there is no subscript. 
                ! (Not true for explicit midpoint)
                ! Evaluate l12 when we are at x_n. Note that this is DEPENDANT on where rd is so l12 = l12(rd). 
                ! Make sure to update appropriately
                l12 = norm2(r_rel) 
                L_n = mu_eff * k * (l0 - l12) / l12

                !Predictor Step
                r_rel_pred = r_rel + (dt / 2) * L_n * r_rel + sdev_d * disp2
                r_rel_pred = r_rel_pred / (1 - dt * L_n / 2)

                ! Corrector L has now changed, as l12 evaluated at the predictor stage is now different. 

                r_rel = r_rel + (dt/2) * L_n * r_rel + sdev_d * disp2

                l12 = norm2(r_rel_pred)  ! For evaluation of L_n+1
                L2_n = mu_eff * k * (l0 - l12) / l12

                r_rel = r_rel / (1 - dt * L2_n / 2)


            end do



        end subroutine
    
        ! Donev: Make this be the first routine in order in the file (since it is the simplest and basic integrator)
        ! and rename to eulerMaruyama for consistency
        subroutine Euler_Maruyama(dt, nsteps, mu_1, mu_2, k, l0, r_cm, r_rel)
            real(wp), intent(in)                        :: dt, mu_1, mu_2, k, l0
            integer, intent(in)                         :: nsteps          
            real(wp), dimension(dim), intent(inout)     :: r_cm, r_rel
            
            ! Local variables           
            real(wp), dimension(dim)                    :: disp1, disp2
            real(wp)                                    :: l12, sdev_cm, sdev_rel, D_rel, D_cm, mu_eff
            integer                                     :: i
    
            ! Since we pass mu_1, mu_2, we must now calculate these quantities here.
            mu_eff = mu_1 + mu_2
            D_rel = kbT * mu_eff
            D_cm = kbT * mu_1 * mu_2 / (mu_1 + mu_2)
    
    
            ! Brownian Motion with Deterministic Drift Realization. 
            do i = 1, nsteps
                call NormalRNGVec(numbers = disp1, n_numbers = dim) ! Mean zero and variance one
                call NormalRNGVec(numbers = disp2, n_numbers = dim) ! Mean zero and variance one
    
                l12 = norm2(r_rel) 
    
                sdev_cm = sqrt(2 * D_cm * dt)
                sdev_rel = sqrt(2 * D_rel * dt)
    
                if (evolve_r_cm) then
                    r_cm = r_cm + sdev_cm * disp1                 
                end if
    
                r_rel = r_rel + mu_eff * k * dt * r_rel * (l0 - l12) / l12 + sdev_rel * disp2
    
                ! If > 1 dimensions:
                !if (dim /= 1) then 
                !    vel = r1 - r2
                !    vel = mu * k * (l12 - l0) * vel / l12
    
               !     r1 = r1 - vel * dt + sdev*disp1 ! Apply one Euler-Maruyama Step to both r1, r2.
                !    r2 = r2 + vel * dt + sdev*disp2 
    
                ! If 1 Dimension
                !else 
                !    r1 = r1 + mu * k * (r2 - r1 - l0) * dt + sdev*disp1
                !    r2 = r2 + mu * k * (r1 - r2 - l0) * dt + sdev*disp2
                !end if
    
            end do
    
        end subroutine   

        ! Explicit midpoint integrator as detailed in "Multiscale Temporal Integrators 
        ! for Fluctuating Hydrodynamics" Delong et. al. 
        ! Implements the scheme found in equation (31), that is, where L = mu_eff * k * (l0-l12)/l12,
        ! x^{p,n+1/2} = x^n + dt/2 * L(x^n) * (x^n) + sqrt(D dt) N_1(0,1)
        ! x^{n+1} = x^n + dt * (L(x^{n+1/2})x^{p,n+1/2} + sqrt(dt D) (N_1(0,1) + N_2(0,1))
        subroutine explicitMidpoint(dt, nsteps, mu_1, mu_2, k, l0, r_cm, r_rel)
            real(wp), intent(in)                        :: dt, k, l0, mu_1, mu_2
            integer, intent(in)                         :: nsteps
            real(wp), dimension(dim), intent(inout)     :: r_cm, r_rel

            ! Local Variables
            real(wp), dimension(dim)                    :: disp1, disp2, r_cm_pred, r_rel_pred, disp3, disp4
            real(wp)                                    :: l12, sdev_cm, sdev_d, mu_eff, D_rel, D_cm
            integer                                     :: i

            mu_eff = mu_1 + mu_2
            D_rel = kbT * mu_eff
            D_cm = kbT * mu_1 * mu_2 / (mu_1 + mu_2)


            ! Explicit Midpoint loop
            do i = 1, nsteps
                ! Donev: Move the call to NormalRNGVec closer to where the variables are actually used
                ! this makes it easier to read the code instead of having to look down where disp1 is used etc.
                ! it would also have helped you put disp1 generation inside the if statement
                call NormalRNGVec(numbers = disp1, n_numbers = dim) ! Mean zero and variance one
                call NormalRNGVec(numbers = disp2, n_numbers = dim) ! Mean zero and variance one
                call NormalRNGVec(numbers = disp3, n_numbers = dim) ! Mean zero and variance one
                call NormalRNGVec(numbers = disp4, n_numbers = dim) ! Mean zero and variance one

                l12 = norm2(r_rel)
                sdev_cm = sqrt(2 * D_cm * dt)
                sdev_d = sqrt(2 * D_rel * dt)

                ! Will want to apply one Explicit Midpoint on ONLY rd 

                ! COM STEP
                ! Donev: IMPORTANT: r_cm should always be evolved using EM regardless of how r_d is evolved
                if (evolve_r_cm) then
                    ! Predictor Step
                    r_cm_pred = r_cm + sqrt(0.5_wp) * sdev_cm * disp1
                    ! Corrector Step
                    r_cm = r_cm + sqrt(0.5_wp) * sdev_cm * (disp1 + disp2)
                end if

                ! R DIFFERENCE STEP
                l12 = norm2(r_rel) ! Evaluate l12 when we are at x_n
                !Predictor Step
                r_rel_pred = r_rel + dt * mu_eff * k * r_rel * (l0 - l12) / (l12 * 2) + sqrt(0.5_wp) * sdev_d * disp3
                ! Corrector L has now changed, as l12 evaluated at the predictor stage is now different. 
                l12 =norm2(r_rel_pred) ! L evaluated at n + 1/2
                r_rel = r_rel + dt * mu_eff * k * r_rel_pred * (l0 - l12) / (l12) + sqrt(0.5_wp) * sdev_d * (disp3 + disp4)
                

            end do



        end subroutine 
        
        ! Donev: This is only correct for l0=0, since it assumes the equation is linear and theta is constant but for you theta changes with l12.
        ! So move this routine somewhere else, not inside this module since this module is "the real deal" and not testing code
        ! Subroutine uses the exact solution of the Ornstein-Uhlenbeck process to solve the dr_d SODE (not the dr_cm SODE)
        ! This is detailed in the Ornstein-Uhlenbeck wikipedia page, and it states that
        ! r_d = r0 exp( -theta * t) + sigma / sqrt(2*theta)exp(-theta*t)W*
        ! Where W* is a Wiener increment with variance exp(2*theta*t) - 1, and also theta = - mu_eff *k * (l0-l12)/l12
        subroutine exactSol(dt, nsteps, mu_eff, k, D_rel, l0, r_rel)   
            real(wp), intent(in)                        :: dt, mu_eff, k, l0, D_rel
            integer, intent(in)                         :: nsteps
            real(wp), dimension(dim), intent(inout)     :: r_rel

            ! Local Variables
            real(wp), dimension(dim)                    :: disp1
            real(wp)                                    :: l12, theta
            integer                                     :: i

            do i = 1, nsteps
                call NormalRNGVec(numbers = disp1, n_numbers = dim) ! Mean zero and variance one


                l12 = norm2(r_rel)
                theta = -mu_eff * k * (l0 - l12) / l12
                r_rel = r_rel * exp(-theta * dt) + sqrt( D_rel / theta) * exp(-theta * dt) * sqrt(exp(2*theta*dt) - 1) * disp1

            end do
            

        end subroutine




end module
