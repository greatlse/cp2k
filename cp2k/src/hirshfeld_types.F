!-----------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations         !
!   Copyright (C) 2000 - 2015  CP2K developers group                          !
!-----------------------------------------------------------------------------!

! *****************************************************************************
!> \brief The types needed for the calculation of Hirshfeld charges and
!>        related functions
!> \par History
!>      11.2014 created [JGH]
!> \author JGH
! *****************************************************************************
MODULE hirshfeld_types
  
  USE input_constants,                 ONLY: shape_function_gaussian
  USE kinds,                           ONLY: dp
  USE pw_types,                        ONLY: pw_p_type,&
                                             pw_release
#include "./common/cp_common_uses.f90"

  IMPLICIT NONE
  PRIVATE

  CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'hirshfeld_types'

  PUBLIC :: hirshfeld_type
  PUBLIC :: create_hirshfeld_type, release_hirshfeld_type
  PUBLIC :: get_hirshfeld_info, set_hirshfeld_info

! *****************************************************************************
!> \brief quantities needed for a Hischfeld based partitioning of real space
!> \author JGH
! *****************************************************************************
  TYPE hirshfeld_type
     LOGICAL                       :: iterative
     INTEGER                       :: shape_function_type
     INTEGER                       :: ref_charge
     TYPE(shape_fn),DIMENSION(:),&
        POINTER                    :: kind_shape_fn
     REAL(KIND=dp),DIMENSION(:),&
        POINTER                    :: charges
     TYPE(pw_p_type), POINTER      :: fnorm
  END TYPE hirshfeld_type

  TYPE shape_fn
     INTEGER                       :: numexp
     REAL(KIND=dp),DIMENSION(:),&
        POINTER                    :: zet
     REAL(KIND=dp),DIMENSION(:),&
        POINTER                    :: coef
  END TYPE shape_fn

! *****************************************************************************

CONTAINS

! *****************************************************************************
!> \brief ...
!> \param hirshfeld_env ...
!> \param error ...
! *****************************************************************************
  SUBROUTINE create_hirshfeld_type(hirshfeld_env,error)
    TYPE(hirshfeld_type), POINTER            :: hirshfeld_env
    TYPE(cp_error_type), INTENT(INOUT)       :: error

    CHARACTER(len=*), PARAMETER :: routineN = 'create_hirshfeld_type', &
      routineP = moduleN//':'//routineN

    INTEGER                                  :: stat
    LOGICAL                                  :: failure

    failure = .FALSE.

    IF(ASSOCIATED(hirshfeld_env)) THEN
       CALL release_hirshfeld_type(hirshfeld_env,error)
    END IF

    ALLOCATE(hirshfeld_env, stat=stat)
    CPPostcondition(stat==0,cp_failure_level,routineP,error,failure)

    hirshfeld_env%iterative = .FALSE.
    hirshfeld_env%shape_function_type = shape_function_gaussian
    NULLIFY(hirshfeld_env%kind_shape_fn)
    NULLIFY(hirshfeld_env%charges)
    NULLIFY(hirshfeld_env%fnorm)

  END SUBROUTINE create_hirshfeld_type

! *****************************************************************************
!> \brief ...
!> \param hirshfeld_env ...
!> \param error ...
! *****************************************************************************
  SUBROUTINE release_hirshfeld_type(hirshfeld_env,error)
    TYPE(hirshfeld_type), POINTER            :: hirshfeld_env
    TYPE(cp_error_type), INTENT(INOUT)       :: error

    CHARACTER(len=*), PARAMETER :: routineN = 'release_hirshfeld_type', &
      routineP = moduleN//':'//routineN

    INTEGER                                  :: ikind, stat
    LOGICAL                                  :: failure
    TYPE(shape_fn), DIMENSION(:), POINTER    :: kind_shape

    failure = .FALSE.

    IF(ASSOCIATED(hirshfeld_env)) THEN

       IF(ASSOCIATED(hirshfeld_env%kind_shape_fn)) THEN
          kind_shape => hirshfeld_env%kind_shape_fn
          DO ikind=1,SIZE(kind_shape)
             IF(ASSOCIATED(hirshfeld_env%kind_shape_fn(ikind)%zet)) THEN
                DEALLOCATE(kind_shape(ikind)%zet, stat=stat)
                CPPostcondition(stat==0,cp_failure_level,routineP,error,failure)
             END IF
             IF(ASSOCIATED(hirshfeld_env%kind_shape_fn(ikind)%coef)) THEN
                DEALLOCATE(kind_shape(ikind)%coef, stat=stat)
                CPPostcondition(stat==0,cp_failure_level,routineP,error,failure)
             END IF
          END DO
          DEALLOCATE(kind_shape, stat=stat)
          CPPostcondition(stat==0,cp_failure_level,routineP,error,failure)
       END IF

       IF(ASSOCIATED(hirshfeld_env%charges)) THEN
          DEALLOCATE(hirshfeld_env%charges, stat=stat)
          CPPostcondition(stat==0,cp_failure_level,routineP,error,failure)
       END IF

       IF (ASSOCIATED(hirshfeld_env%fnorm)) THEN
          CALL pw_release(hirshfeld_env%fnorm%pw,error=error)
          DEALLOCATE(hirshfeld_env%fnorm,stat=stat)
          CPPostconditionNoFail(stat==0,cp_warning_level,routineP,error)
       ENDIF

       DEALLOCATE(hirshfeld_env, stat=stat)
       CPPostcondition(stat==0,cp_failure_level,routineP,error,failure)

    END IF

  END SUBROUTINE release_hirshfeld_type

! *****************************************************************************
!> \brief ...
!> \param hirshfeld_env ...
!> \param shape_function_type ...
!> \param iterative ...
!> \param ref_charge ...
!> \param fnorm ...
!> \param error ...
! *****************************************************************************
  SUBROUTINE get_hirshfeld_info(hirshfeld_env,shape_function_type,iterative,&
             ref_charge,fnorm,error)
    TYPE(hirshfeld_type), POINTER            :: hirshfeld_env
    INTEGER, INTENT(OUT), OPTIONAL           :: shape_function_type
    LOGICAL, INTENT(OUT), OPTIONAL           :: iterative
    INTEGER, INTENT(OUT), OPTIONAL           :: ref_charge
    TYPE(pw_p_type), OPTIONAL, POINTER       :: fnorm
    TYPE(cp_error_type), INTENT(INOUT)       :: error

    CHARACTER(len=*), PARAMETER :: routineN = 'get_hirshfeld_info', &
      routineP = moduleN//':'//routineN

    LOGICAL                                  :: failure

    failure = .FALSE.
    CPPrecondition(ASSOCIATED(hirshfeld_env),cp_failure_level,routineP,error,failure)

    IF(PRESENT(shape_function_type)) THEN
       shape_function_type = hirshfeld_env%shape_function_type
    END IF
    IF(PRESENT(iterative)) THEN
       iterative = hirshfeld_env%iterative
    END IF
    IF(PRESENT(ref_charge)) THEN
       ref_charge = hirshfeld_env%ref_charge
    END IF
    IF(PRESENT(fnorm)) THEN
       fnorm => hirshfeld_env%fnorm
    END IF

  END SUBROUTINE get_hirshfeld_info

! *****************************************************************************
!> \brief ...
!> \param hirshfeld_env ...
!> \param shape_function_type ...
!> \param iterative ...
!> \param ref_charge ...
!> \param fnorm ...
!> \param error ...
! *****************************************************************************
  SUBROUTINE set_hirshfeld_info(hirshfeld_env,shape_function_type,iterative,&
             ref_charge,fnorm,error)
    TYPE(hirshfeld_type), POINTER            :: hirshfeld_env
    INTEGER, INTENT(IN), OPTIONAL            :: shape_function_type
    LOGICAL, INTENT(IN), OPTIONAL            :: iterative
    INTEGER, INTENT(IN), OPTIONAL            :: ref_charge
    TYPE(pw_p_type), OPTIONAL, POINTER       :: fnorm
    TYPE(cp_error_type), INTENT(INOUT)       :: error

    CHARACTER(len=*), PARAMETER :: routineN = 'set_hirshfeld_info', &
      routineP = moduleN//':'//routineN

    LOGICAL                                  :: failure

    failure = .FALSE.
    CPPrecondition(ASSOCIATED(hirshfeld_env),cp_failure_level,routineP,error,failure)

    IF(PRESENT(shape_function_type)) THEN
       hirshfeld_env%shape_function_type = shape_function_type
    END IF
    IF(PRESENT(iterative)) THEN
       hirshfeld_env%iterative = iterative
    END IF
    IF(PRESENT(ref_charge)) THEN
       hirshfeld_env%ref_charge = ref_charge
    END IF
    IF(PRESENT(fnorm)) THEN
       hirshfeld_env%fnorm => fnorm
    END IF

  END SUBROUTINE set_hirshfeld_info
! *****************************************************************************

END MODULE hirshfeld_types
