!-----------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations         !
!   Copyright (C) 2000 - 2015  CP2K developers group                          !
!-----------------------------------------------------------------------------!

! *****************************************************************************
!> \brief Routines for that prepare rtp and EMD
!> \author Florian Schiffmann (02.09)
! *****************************************************************************
MODULE rt_propagator_init

  USE cp_control_types,                ONLY: dft_control_type,&
                                             rtp_control_type
  USE cp_dbcsr_interface,              ONLY: &
       cp_dbcsr_copy, cp_dbcsr_create, cp_dbcsr_deallocate_matrix, &
       cp_dbcsr_filter, cp_dbcsr_init, cp_dbcsr_multiply, cp_dbcsr_p_type, &
       cp_dbcsr_scale, cp_dbcsr_type
  USE cp_dbcsr_operations,             ONLY: copy_dbcsr_to_fm,&
                                             copy_fm_to_dbcsr
  USE cp_dbcsr_util,                   ONLY: lanczos_alg_serial
  USE cp_fm_basic_linalg,              ONLY: cp_fm_scale,&
                                             cp_fm_upper_to_full
  USE cp_fm_diag,                      ONLY: cp_fm_syevd
  USE cp_fm_types,                     ONLY: cp_fm_create,&
                                             cp_fm_get_info,&
                                             cp_fm_p_type,&
                                             cp_fm_release,&
                                             cp_fm_set_all,&
                                             cp_fm_to_fm,&
                                             cp_fm_type
  USE cp_gemm_interface,               ONLY: cp_gemm
  USE dm_ls_scf_methods,               ONLY: density_matrix_trs4
  USE input_constants,                 ONLY: do_arnoldi,&
                                             do_bch,&
                                             do_cn,&
                                             do_em,&
                                             do_etrs,&
                                             do_pade,&
                                             do_taylor
  USE iterate_matrix,                  ONLY: matrix_sqrt_Newton_Schulz
  USE kinds,                           ONLY: dp
  USE qs_environment_types,            ONLY: get_qs_env,&
                                             qs_environment_type
  USE qs_ks_methods,                   ONLY: qs_ks_update_qs_env
  USE qs_ks_types,                     ONLY: qs_ks_env_type
  USE rt_make_propagators,             ONLY: compute_exponential,&
                                             compute_exponential_sparse,&
                                             propagate_arnoldi
  USE rt_matrix_exp,                   ONLY: get_nsquare_norder
  USE rt_propagation_methods,          ONLY: calc_SinvH,&
                                             calc_update_rho,&
                                             calc_update_rho_sparse,&
                                             put_data_to_history,&
                                             s_matrices_create
  USE rt_propagation_types,            ONLY: get_rtp,&
                                             rt_prop_type
  USE rt_propagation_utils,            ONLY: calc_S_derivs
  USE timings,                         ONLY: timeset,&
                                             timestop
#include "./common/cp_common_uses.f90"

  IMPLICIT NONE

  PRIVATE

  CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'rt_propagator_init'

  PUBLIC :: init_propagators,&
            init_emd_propagators,&
            rt_initialize_rho_from_ks


CONTAINS


! *****************************************************************************
!> \brief prepares the initial matrices for the propagators
!> \param qs_env ...
!> \param error ...
!> \author Florian Schiffmann (02.09)
! *****************************************************************************

  SUBROUTINE init_propagators(qs_env,error)

    TYPE(qs_environment_type), POINTER       :: qs_env
    TYPE(cp_error_type), INTENT(inout)       :: error

    CHARACTER(len=*), PARAMETER :: routineN = 'init_propagators', &
      routineP = moduleN//':'//routineN

    INTEGER                                  :: i, imat, unit_nr
    REAL(KIND=dp)                            :: dt, prefac
    TYPE(cp_dbcsr_p_type), DIMENSION(:), &
      POINTER                                :: exp_H_new, exp_H_old, &
                                                matrix_ks, matrix_ks_im, &
                                                propagator_matrix, rho_old, &
                                                s_mat
    TYPE(cp_fm_p_type), DIMENSION(:), &
      POINTER                                :: mos_new, mos_next, mos_old
    TYPE(cp_logger_type), POINTER            :: logger
    TYPE(dft_control_type), POINTER          :: dft_control
    TYPE(rt_prop_type), POINTER              :: rtp
    TYPE(rtp_control_type), POINTER          :: rtp_control

    CALL get_qs_env(qs_env,&
         rtp=rtp,&
         dft_control=dft_control,&
         matrix_s=s_mat,&
         matrix_ks=matrix_ks,&
         matrix_ks_im=matrix_ks_im,&
         error=error)

    rtp_control=>dft_control%rtp_control
    CALL get_rtp (rtp=rtp,exp_H_old=exp_H_old,exp_H_new=exp_H_new,&
                  propagator_matrix=propagator_matrix,dt=dt,error=error)
    CALL s_matrices_create (s_mat,rtp,error)
    CALL calc_SinvH(rtp,matrix_ks,matrix_ks_im,rtp_control,error)
    DO i=1,SIZE(exp_H_old)
       CALL cp_dbcsr_copy(exp_H_old(i)%matrix,exp_H_new(i)%matrix,error=error)
    END DO
    ! use the fact that CN propagator is a first order pade approximation on the EM propagator
    IF(rtp_control%propagator==do_cn)THEN
       rtp%orders(1,:)=0;rtp%orders(2,:)=1; rtp_control%mat_exp=do_pade; rtp_control%propagator=do_em
    ELSE IF(rtp_control%mat_exp==do_pade.OR.rtp_control%mat_exp==do_taylor) THEN
       IF(rtp%linear_scaling) THEN
          CALL get_maxabs_eigval_sparse(rtp,s_mat,matrix_ks,rtp_control,error)
       ELSE
          CALL get_maxabs_eigval(rtp,s_mat,matrix_ks,rtp_control,error)
       END IF
    END IF
    IF(rtp_control%mat_exp==do_pade.AND.rtp%linear_scaling) THEN
       ! get a useful output_unit
       logger => cp_error_get_logger(error)
       IF (logger%para_env%mepos==logger%para_env%source) THEN
          unit_nr=cp_logger_get_default_unit_nr(logger,local=.TRUE.)
          WRITE(unit_nr,*) "linear_scaling currently does not support pade exponentials, switching to taylor"
       ENDIF
       rtp_control%mat_exp=do_taylor
    ENDIF
    ! We have no clue yet about next H so we use initial H for t and t+dt
    ! Due to different nature of the propagator the prefactor has to be adopted
    SELECT CASE(rtp_control%propagator)
      CASE(do_etrs)
        prefac=-0.5_dp*dt
      CASE(do_em)
        prefac=-1.0_dp*dt
    END SELECT 
    DO imat=1,SIZE(exp_H_new)
        CALL cp_dbcsr_copy(propagator_matrix(imat)%matrix,exp_H_new(imat)%matrix,error=error)
        CALL cp_dbcsr_scale(propagator_matrix(imat)%matrix,prefac,error=error)
    END DO

    ! For ETRS this bit could be avoided but it drastically simplifies the workflow afterwards.
    ! If we compute the half propagated mos/exponential already here, we ensure everything is done
    ! with the correct S matrix and all information as during RTP/EMD are computed.
    ! Therefore we might accept to compute an unnesscesary expoenential but understand the code afterwards
    IF(rtp_control%propagator==do_etrs)THEN
       IF(rtp_control%mat_exp==do_arnoldi)THEN
          rtp%iter=0
          CALL propagate_arnoldi(rtp,rtp_control,error)
          CALL get_rtp(rtp=rtp,mos_new=mos_new,mos_next=mos_next,error=error)
          DO imat=1,SIZE(mos_new)
             CALL cp_fm_to_fm(mos_new(imat)%matrix,mos_next(imat)%matrix,error)
          END DO
       ELSEIF(rtp_control%mat_exp==do_bch) THEN
       ELSE
          IF(rtp%linear_scaling) THEN
             CALL compute_exponential_sparse(exp_H_new,propagator_matrix,rtp_control,rtp,error=error)
          ELSE
             CALL compute_exponential(exp_H_new,propagator_matrix,rtp_control,rtp,error=error)
          END IF
          DO imat=1,SIZE(exp_H_new)
             CALL cp_dbcsr_copy(exp_H_old(imat)%matrix,exp_H_new(imat)%matrix,error=error)
          END DO
       END IF
    END IF

    IF(rtp%linear_scaling) THEN
       CALL get_rtp (rtp=rtp,rho_old=rho_old,error=error)
    ELSE
       CALL get_rtp (rtp=rtp,mos_old=mos_old,error=error)
    ENDIF
    CALL put_data_to_history(rtp,mos=mos_old,s_mat=s_mat,ihist=1,rho=rho_old,error=error)

  END SUBROUTINE init_propagators

! *****************************************************************************
!> \brief gets an estimate for the 2-norm of KS (diagnaliztion of KS) and
!>        calculates the order and number of squaring steps for Taylor or
!>        Pade matrix exponential
!> \param rtp ...
!> \param s_mat ...
!> \param matrix_ks ...
!> \param rtp_control ...
!> \param error ...
!> \author Florian Schiffmann (02.09)
! *****************************************************************************

  SUBROUTINE get_maxabs_eigval(rtp,s_mat,matrix_ks,rtp_control,error)
    TYPE(rt_prop_type), POINTER              :: rtp
    TYPE(cp_dbcsr_p_type), DIMENSION(:), &
      POINTER                                :: s_mat, matrix_ks
    TYPE(rtp_control_type), POINTER          :: rtp_control
    TYPE(cp_error_type), INTENT(inout)       :: error

    CHARACTER(len=*), PARAMETER :: routineN = 'get_maxabs_eigval', &
      routineP = moduleN//':'//routineN
    REAL(KIND=dp), PARAMETER                 :: one = 1.0_dp , zero = 0.0_dp

    INTEGER                                  :: handle, ispin, method, ndim, &
                                                stat
    LOGICAL                                  :: emd, failure
    REAL(dp)                                 :: max_eval, min_eval, norm2, &
                                                scale, t
    REAL(dp), ALLOCATABLE, DIMENSION(:)      :: eigval_H
    TYPE(cp_dbcsr_type), POINTER             :: S_inv
    TYPE(cp_fm_type), POINTER                :: eigvec_H, H_fm, S_half, &
                                                S_inv_fm, S_minus_half, tmp, &
                                                tmp_mat_H

    CALL timeset(routineN,handle)
    failure=.FALSE.

    CALL get_rtp(rtp=rtp,S_inv=S_inv,dt=t,error=error)

    CALL cp_fm_create(S_inv_fm,&
          matrix_struct=rtp%ao_ao_fmstruct,&
          name="S_inv",&
          error=error)
    CALL copy_dbcsr_to_fm(S_inv,S_inv_fm,error=error)

    CALL cp_fm_create(S_half,&
          matrix_struct=rtp%ao_ao_fmstruct,&
          name="S_half",&
          error=error)

    CALL cp_fm_create(S_minus_half,&
          matrix_struct=rtp%ao_ao_fmstruct,&
          name="S_minus_half",&
          error=error)

    CALL cp_fm_create(H_fm,&
         matrix_struct=rtp%ao_ao_fmstruct,&
         name="RTP_H_FM",&
         error=error)

    CALL cp_fm_create(tmp_mat_H,&
         matrix_struct=rtp%ao_ao_fmstruct,&
         name="TMP_H",&
         error=error)

    ndim=S_inv_fm%matrix_struct%nrow_global
    scale=1.0_dp
    IF(rtp_control%propagator==do_etrs) scale=2.0_dp
    t=-t/scale

    ! Create the overlap matrices

    CALL cp_fm_create(tmp,&
         matrix_struct=rtp%ao_ao_fmstruct,&
         name="tmp_mat",&
         error=error)

    CALL cp_fm_create(eigvec_H,&
         matrix_struct=rtp%ao_ao_fmstruct,&
         name="tmp_EVEC",&
         error=error)

    ALLOCATE(eigval_H(ndim),stat=stat)
    CPPostcondition(stat==0,cp_failure_level,routineP,error,failure)
    CALL copy_dbcsr_to_fm(s_mat(1)%matrix,tmp,error=error)
    CALL cp_fm_upper_to_full(tmp,eigvec_H,error)

    CALL cp_fm_syevd(tmp,eigvec_H,eigval_H,error=error)

    eigval_H(:)=one/eigval_H(:)
    CALL backtransform_matrix(eigval_H,eigvec_H,S_inv_fm,error)
    eigval_H(:)=SQRT(eigval_H(:))
    CALL backtransform_matrix(eigval_H,eigvec_H,S_minus_half,error)
    eigval_H(:)=one/eigval_H(:)
    CALL backtransform_matrix(eigval_H,eigvec_H,S_half,error)
    CALL cp_fm_release(eigvec_H,error)
    CALL cp_fm_release(tmp,error)

    IF(rtp_control%mat_exp==do_taylor)method=1
    IF(rtp_control%mat_exp==do_pade)method=2
    emd=(.NOT.rtp_control%fixed_ions)

    DO ispin=1,SIZE(matrix_ks)

       CALL copy_dbcsr_to_fm(matrix_ks(ispin)%matrix,H_fm,error=error)
       CALL cp_fm_upper_to_full(H_fm,tmp_mat_H,error)
       CALL cp_fm_scale(t,H_fm,error)

       CALL cp_gemm("N","N",ndim,ndim,ndim,one,H_fm,S_minus_half,zero,&
            tmp_mat_H,error)
       CALL cp_gemm("N","N",ndim,ndim,ndim,one,S_minus_half,tmp_mat_H,zero,&
            H_fm,error)

       CALL cp_fm_syevd(H_fm,tmp_mat_H,eigval_H,error=error)
       min_eval=MINVAL(eigval_H)
       max_eval=MAXVAL(eigval_H)
       norm2=2.0_dp*MAX(ABS(min_eval),ABS(max_eval))
       CALL get_nsquare_norder(norm2,rtp%orders(1,ispin),rtp%orders(2,ispin),&
            rtp_control%eps_exp,method ,emd,error)
    END DO

    DEALLOCATE(eigval_H,stat=stat)
    CPPostcondition(stat==0,cp_failure_level,routineP,error,failure)

    CALL copy_fm_to_dbcsr(S_inv_fm,S_inv,error=error)
    CALL cp_fm_release(S_inv_fm,error)
    CALL cp_fm_release(S_half,error)
    CALL cp_fm_release(S_minus_half,error)
    CALL cp_fm_release(H_fm,error)
    CALL cp_fm_release(tmp_mat_H,error)

    CALL timestop(handle)

  END SUBROUTINE get_maxabs_eigval

! *****************************************************************************
!> \brief gets an estimate for the 2-norm of KS (diagnaliztion of KS) and
!>        calculates the order and number of squaring steps for Taylor or
!>        Pade matrix exponential. Based on the full matrix code.
!> \param rtp ...
!> \param s_mat ...
!> \param matrix_ks ...
!> \param rtp_control ...
!> \param error ...
!> \author Samuel Andermatt (02.14)
! *****************************************************************************

  SUBROUTINE get_maxabs_eigval_sparse(rtp,s_mat,matrix_ks,rtp_control,error)
    TYPE(rt_prop_type), POINTER              :: rtp
    TYPE(cp_dbcsr_p_type), DIMENSION(:), &
      POINTER                                :: s_mat, matrix_ks
    TYPE(rtp_control_type), POINTER          :: rtp_control
    TYPE(cp_error_type), INTENT(inout)       :: error

    CHARACTER(len=*), PARAMETER :: routineN = 'get_maxabs_eigval_sparse', &
      routineP = moduleN//':'//routineN
    REAL(KIND=dp), PARAMETER                 :: one = 1.0_dp , zero = 0.0_dp

    INTEGER                                  :: handle, ispin, method
    LOGICAL                                  :: converged, emd
    REAL(dp)                                 :: max_ev, min_ev, norm2, scale, &
                                                t
    TYPE(cp_dbcsr_type), POINTER             :: s_half, s_minus_half, tmp, &
                                                tmp2

    CALL timeset(routineN,handle)

    CALL get_rtp(rtp=rtp,dt=t,error=error)

    NULLIFY(s_half)
    ALLOCATE(s_half)
    CALL cp_dbcsr_init(s_half,error=error)
    CALL cp_dbcsr_create(s_half,template=s_mat(1)%matrix,error=error)
    NULLIFY(s_minus_half)
    ALLOCATE(s_minus_half)
    CALL cp_dbcsr_init(s_minus_half,error=error)
    CALL cp_dbcsr_create(s_minus_half,template=s_mat(1)%matrix,error=error)
    NULLIFY(tmp)
    ALLOCATE(tmp)
    CALL cp_dbcsr_init(tmp,error=error)
    CALL cp_dbcsr_create(tmp,template=s_mat(1)%matrix,matrix_type="N",error=error)
    NULLIFY(tmp2)
    ALLOCATE(tmp2)
    CALL cp_dbcsr_init(tmp2,error=error)
    CALL cp_dbcsr_create(tmp2,template=s_mat(1)%matrix,matrix_type="N",error=error)
    scale=1.0_dp
    IF(rtp_control%propagator==do_etrs)scale=2.0_dp
    t=-t/scale
    emd=(.NOT.rtp_control%fixed_ions)

    IF(rtp_control%mat_exp==do_taylor)method=1
    IF(rtp_control%mat_exp==do_pade)method=2
    CALL matrix_sqrt_Newton_Schulz(s_half,s_minus_half,s_mat(1)%matrix,rtp%filter_eps,&
         rtp%newton_schulz_order,rtp%lanzcos_threshold,rtp%lanzcos_max_iter,error=error)
    DO ispin=1,SIZE(matrix_ks)
       CALL cp_dbcsr_multiply("N","N",t,matrix_ks(ispin)%matrix,s_minus_half,zero,tmp,&
            filter_eps=rtp%filter_eps,error=error)
       CALL cp_dbcsr_multiply("N","N",one,s_minus_half,tmp,zero,tmp2,&
            filter_eps=rtp%filter_eps,error=error)
       CALL lanczos_alg_serial(tmp2, max_ev, min_ev, threshold=rtp%lanzcos_threshold, &
            max_iter=rtp%lanzcos_max_iter, converged=converged, error=error)
       norm2=2.0_dp*MAX(ABS(min_ev),ABS(max_ev))
       CALL get_nsquare_norder(norm2,rtp%orders(1,ispin),rtp%orders(2,ispin),&
            rtp_control%eps_exp,method,emd,error)
    END DO

    CALL cp_dbcsr_deallocate_matrix(s_half,error=error)
    CALL cp_dbcsr_deallocate_matrix(s_minus_half,error=error)
    CALL cp_dbcsr_deallocate_matrix(tmp,error=error)
    CALL cp_dbcsr_deallocate_matrix(tmp2,error=error)

    CALL timestop(handle)

  END SUBROUTINE

! *****************************************************************************
!> \brief Is still left from diagonalization, should be removed later but is
!>  still needed for the guess for the padé/Taylor method
!> \param Eval ...
!> \param eigenvec ...
!> \param matrix ...
!> \param error ...
!> \author Florian Schiffmann (02.09)
! *****************************************************************************

  SUBROUTINE backtransform_matrix(Eval,eigenvec,matrix,error)

    REAL(dp), DIMENSION(:), INTENT(in)       :: Eval
    TYPE(cp_fm_type), POINTER                :: eigenvec, matrix
    TYPE(cp_error_type), INTENT(inout)       :: error

    CHARACTER(len=*), PARAMETER :: routineN = 'backtransform_matrix', &
      routineP = moduleN//':'//routineN
    REAL(KIND=dp), PARAMETER                 :: one = 1.0_dp , zero = 0.0_dp

    INTEGER                                  :: handle, i, j, l, ncol_local, &
                                                ndim, nrow_local
    INTEGER, DIMENSION(:), POINTER           :: col_indices, row_indices
    TYPE(cp_fm_type), POINTER                :: tmp

    CALL timeset(routineN,handle)
    CALL cp_fm_create(tmp,&
         matrix_struct=matrix%matrix_struct,&
         name="TMP_BT",&
         error=error)
    CALL cp_fm_get_info(matrix, nrow_local=nrow_local, ncol_local=ncol_local,&
         row_indices=row_indices,col_indices=col_indices,error=error)

    ndim=matrix%matrix_struct%nrow_global

    CALL cp_fm_set_all(tmp,zero,zero,error)
    DO i=1,ncol_local
       l=col_indices(i)
       DO j=1,nrow_local
          tmp%local_data(j,i)=eigenvec%local_data(j,i)*Eval(l)
       END DO
    END DO
    CALL cp_gemm("N","T",ndim,ndim,ndim,one,tmp,eigenvec,zero,&
         matrix ,error)

    CALL cp_fm_release(tmp,error)
    CALL timestop(handle)

  END SUBROUTINE backtransform_matrix

! *****************************************************************************
!> \brief computs all matrices needed to initialize emd (S_derivs, SinvH,
!>        SinvB and forces)
!> \param qs_env ...
!> \param error ...
!> \author Florian Schiffmann (02.09)
! *****************************************************************************

  SUBROUTINE init_emd_propagators(qs_env,error)
    TYPE(qs_environment_type), POINTER       :: qs_env
    TYPE(cp_error_type), INTENT(inout)       :: error

    CHARACTER(len=*), PARAMETER :: routineN = 'init_emd_propagators', &
      routineP = moduleN//':'//routineN

    TYPE(qs_ks_env_type), POINTER            :: ks_env

       IF (qs_env%rtp%linear_scaling) THEN
          CALL calc_update_rho_sparse(qs_env,error=error)
       ELSE
          CALL calc_update_rho(qs_env,error)
       ENDIF
       CALL get_qs_env(qs_env=qs_env,ks_env=ks_env,error=error)
       !derivatives of the potential
       CALL qs_ks_update_qs_env(qs_env, calculate_forces=.FALSE., error=error)
       !derivativs of the overlap needed for EMD
       CALL calc_S_derivs(qs_env,error)
       ! a bit hidden, but computes SinvH and SinvB (calc_SinvH for CN,EM and ARNOLDI)
       ! make_etrs_exp in case of ETRS in combination with TAYLOR and PADE
       CALL init_propagators(qs_env,error)
   END SUBROUTINE init_emd_propagators


! *****************************************************************************
!> \brief Computes the density matrix starting from the kohn-sham matrix
!> \param rtp ...
!> \param matrix_ks ...
!> \param matrix_s ...
!> \param nelectron_spin ...
!> \param orthonormal ...
!> \param error ...
!> \author Samuel Andermatt (03.14)
! *****************************************************************************

   SUBROUTINE rt_initialize_rho_from_ks(rtp,matrix_ks,matrix_s,nelectron_spin,orthonormal,error)

    TYPE(rt_prop_type), POINTER              :: rtp
    TYPE(cp_dbcsr_p_type), DIMENSION(:), &
      POINTER                                :: matrix_ks, matrix_s
    INTEGER, DIMENSION(2)                    :: nelectron_spin
    LOGICAL                                  :: orthonormal
    TYPE(cp_error_type), INTENT(inout)       :: error

    CHARACTER(len=*), PARAMETER :: routineN = 'rt_initialize_rho_from_ks', &
      routineP = moduleN//':'//routineN
    REAL(KIND=dp), PARAMETER                 :: one = 1.0_dp , zero = 0.0_dp

    INTEGER                                  :: i, im, ispin, &
                                                nelectron_spin_real, re
    REAL(KIND=dp)                            :: e_homo, e_lumo, e_mu
    TYPE(cp_dbcsr_p_type), DIMENSION(:), &
      POINTER                                :: rho_new, rho_old
    TYPE(cp_dbcsr_type), POINTER             :: S_half, S_minus_half, tmp

    CALL get_rtp(rtp=rtp,rho_old=rho_old,S_half=S_half,S_minus_half=S_minus_half,rho_new=rho_new,error=error)
    !The inverse of S will be calculated twice in the first step, but preventing that would make things more complicated
    CALL matrix_sqrt_Newton_Schulz(S_half,S_minus_half,matrix_s(1)%matrix,rtp%filter_eps,&
         rtp%newton_schulz_order,rtp%lanzcos_threshold,rtp%lanzcos_max_iter,error=error)
    NULLIFY(tmp)
    ALLOCATE(tmp)
    CALL cp_dbcsr_init(tmp,error=error)
    CALL cp_dbcsr_create(tmp,template=matrix_ks(1)%matrix,matrix_type="N",error=error)

    e_homo = 0.0_dp
    e_lumo = 0.0_dp
    e_mu = 0.0_dp

    DO ispin=1,SIZE(matrix_ks)
       re=2*ispin-1
       im=2*ispin
       nelectron_spin_real=nelectron_spin(ispin)
       IF(SIZE(matrix_ks)==1) nelectron_spin_real=nelectron_spin_real/2
       CALL density_matrix_trs4(rho_old(re)%matrix, matrix_ks(ispin)%matrix, S_minus_half, &
            nelectron_spin_real, rtp%filter_eps, e_homo, e_lumo, e_mu, .FALSE., tmp,&
            max_iter_lanczos=rtp%lanzcos_max_iter, eps_lanczos=rtp%lanzcos_threshold, error=error)
       IF(SIZE(matrix_ks)==1) CALL cp_dbcsr_scale(rho_old(re)%matrix,2.0_dp,error=error)
       IF(orthonormal) THEN
          CALL cp_dbcsr_multiply("N","N",one,S_half,rho_old(re)%matrix,zero,tmp,filter_eps=rtp%filter_eps_small,error=error)
          CALL cp_dbcsr_multiply("N","N",one,tmp,S_half,zero,rho_old(re)%matrix,filter_eps=rtp%filter_eps_small,error=error)
          CALL cp_dbcsr_multiply("N","N",one,S_half,rho_old(im)%matrix,zero,tmp,filter_eps=rtp%filter_eps_small,error=error)
          CALL cp_dbcsr_multiply("N","N",one,tmp,S_half,zero,rho_old(im)%matrix,filter_eps=rtp%filter_eps_small,error=error)
       ENDIF
       CALL cp_dbcsr_filter(rho_old(re)%matrix,eps=rtp%filter_eps,error=error)
    END DO

    DO i=1,SIZE(rho_new)
       CALL cp_dbcsr_copy(rho_new(i)%matrix,rho_old(i)%matrix,error=error)
    ENDDO

    CALL cp_dbcsr_deallocate_matrix(tmp,error=error)
   END SUBROUTINE rt_initialize_rho_from_ks

END MODULE rt_propagator_init
