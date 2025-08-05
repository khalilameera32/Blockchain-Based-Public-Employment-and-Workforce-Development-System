;; Unemployment Benefits Processing Contract
;; Streamlines unemployment insurance claims and payments

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u300))
(define-constant ERR-CLAIM-NOT-FOUND (err u301))
(define-constant ERR-INVALID-STATUS (err u302))
(define-constant ERR-INVALID-INPUT (err u303))
(define-constant ERR-CLAIM-EXISTS (err u304))
(define-constant ERR-INSUFFICIENT-FUNDS (err u305))
(define-constant ERR-CLAIM-EXPIRED (err u306))

;; Data Variables
(define-data-var next-claim-id uint u1)
(define-data-var next-certification-id uint u1)
(define-data-var benefits-fund uint u0)

;; Data Maps
(define-map unemployment-claims
  { claim-id: uint }
  {
    claimant: principal,
    previous-employer: principal,
    last-work-date: uint,
    weekly-benefit-amount: uint,
    total-benefit-amount: uint,
    claim-date: uint,
    status: (string-ascii 20),
    approved-date: (optional uint),
    expiration-date: uint,
    weeks-claimed: uint,
    weeks-paid: uint
  }
)

(define-map weekly-certifications
  { certification-id: uint }
  {
    claim-id: uint,
    week-ending: uint,
    work-searched: bool,
    earnings: uint,
    certification-date: uint,
    status: (string-ascii 20),
    payment-amount: uint,
    payment-date: (optional uint)
  }
)

(define-map benefits-administrators
  { admin: principal }
  { authorized: bool }
)

(define-map claimant-eligibility
  { claimant: principal }
  {
    base-period-wages: uint,
    quarters-worked: uint,
    eligible: bool,
    disqualifications: (list 5 (string-ascii 50))
  }
)

(define-map employer-accounts
  { employer: principal }
  {
    account-balance: uint,
    contribution-rate: uint,
    total-contributions: uint,
    total-charges: uint
  }
)

;; Authorization Functions
(define-private (is-authorized (user principal))
  (or
    (is-eq user CONTRACT-OWNER)
    (default-to false (get authorized (map-get? benefits-administrators { admin: user })))
  )
)

;; Administrative Functions
(define-public (add-administrator (admin principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (ok (map-set benefits-administrators { admin: admin } { authorized: true }))
  )
)

(define-public (remove-administrator (admin principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (ok (map-delete benefits-administrators { admin: admin }))
  )
)

(define-public (deposit-benefits-fund (amount uint))
  (begin
    (asserts! (is-authorized tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (> amount u0) ERR-INVALID-INPUT)
    (var-set benefits-fund (+ (var-get benefits-fund) amount))
    (ok (var-get benefits-fund))
  )
)

;; Eligibility Management
(define-public (set-claimant-eligibility
  (claimant principal)
  (base-period-wages uint)
  (quarters-worked uint)
  (eligible bool)
  (disqualifications (list 5 (string-ascii 50)))
)
  (begin
    (asserts! (is-authorized tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (<= quarters-worked u4) ERR-INVALID-INPUT)

    (ok (map-set claimant-eligibility
      { claimant: claimant }
      {
        base-period-wages: base-period-wages,
        quarters-worked: quarters-worked,
        eligible: eligible,
        disqualifications: disqualifications
      }
    ))
  )
)

;; Claims Management
(define-public (file-unemployment-claim
  (claimant principal)
  (previous-employer principal)
  (last-work-date uint)
  (weekly-benefit-amount uint)
)
  (let
    (
      (claim-id (var-get next-claim-id))
      (eligibility (unwrap! (map-get? claimant-eligibility { claimant: claimant }) ERR-INVALID-INPUT))
      (total-benefit-amount (* weekly-benefit-amount u26)) ;; 26 weeks maximum
      (expiration-date (+ block-height u15724800)) ;; ~52 weeks in blocks
    )
    (asserts! (is-authorized tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (get eligible eligibility) ERR-INVALID-INPUT)
    (asserts! (> weekly-benefit-amount u0) ERR-INVALID-INPUT)
    (asserts! (< last-work-date block-height) ERR-INVALID-INPUT)

    (map-set unemployment-claims
      { claim-id: claim-id }
      {
        claimant: claimant,
        previous-employer: previous-employer,
        last-work-date: last-work-date,
        weekly-benefit-amount: weekly-benefit-amount,
        total-benefit-amount: total-benefit-amount,
        claim-date: block-height,
        status: "pending",
        approved-date: none,
        expiration-date: expiration-date,
        weeks-claimed: u0,
        weeks-paid: u0
      }
    )
    (var-set next-claim-id (+ claim-id u1))
    (ok claim-id)
  )
)

(define-public (approve-claim (claim-id uint))
  (let
    ((claim (unwrap! (map-get? unemployment-claims { claim-id: claim-id }) ERR-CLAIM-NOT-FOUND)))
    (asserts! (is-authorized tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status claim) "pending") ERR-INVALID-STATUS)

    (ok (map-set unemployment-claims
      { claim-id: claim-id }
      (merge claim {
        status: "approved",
        approved-date: (some block-height)
      })
    ))
  )
)

(define-public (deny-claim (claim-id uint))
  (let
    ((claim (unwrap! (map-get? unemployment-claims { claim-id: claim-id }) ERR-CLAIM-NOT-FOUND)))
    (asserts! (is-authorized tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status claim) "pending") ERR-INVALID-STATUS)

    (ok (map-set unemployment-claims
      { claim-id: claim-id }
      (merge claim { status: "denied" })
    ))
  )
)

;; Weekly Certification
(define-public (submit-weekly-certification
  (claim-id uint)
  (week-ending uint)
  (work-searched bool)
  (earnings uint)
)
  (let
    (
      (certification-id (var-get next-certification-id))
      (claim (unwrap! (map-get? unemployment-claims { claim-id: claim-id }) ERR-CLAIM-NOT-FOUND))
    )
    (asserts! (is-authorized tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status claim) "approved") ERR-INVALID-STATUS)
    (asserts! (< block-height (get expiration-date claim)) ERR-CLAIM-EXPIRED)
    (asserts! (< (get weeks-claimed claim) u26) ERR-INVALID-INPUT)

    (map-set weekly-certifications
      { certification-id: certification-id }
      {
        claim-id: claim-id,
        week-ending: week-ending,
        work-searched: work-searched,
        earnings: earnings,
        certification-date: block-height,
        status: "pending",
        payment-amount: u0,
        payment-date: none
      }
    )

    ;; Update claim weeks claimed
    (map-set unemployment-claims
      { claim-id: claim-id }
      (merge claim { weeks-claimed: (+ (get weeks-claimed claim) u1) })
    )

    (var-set next-certification-id (+ certification-id u1))
    (ok certification-id)
  )
)

(define-public (process-weekly-payment (certification-id uint))
  (let
    (
      (certification (unwrap! (map-get? weekly-certifications { certification-id: certification-id }) ERR-CLAIM-NOT-FOUND))
      (claim (unwrap! (map-get? unemployment-claims { claim-id: (get claim-id certification) }) ERR-CLAIM-NOT-FOUND))
      (payment-amount (calculate-payment-amount (get weekly-benefit-amount claim) (get earnings certification)))
    )
    (asserts! (is-authorized tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status certification) "pending") ERR-INVALID-STATUS)
    (asserts! (get work-searched certification) ERR-INVALID-INPUT)
    (asserts! (>= (var-get benefits-fund) payment-amount) ERR-INSUFFICIENT-FUNDS)

    ;; Update certification with payment
    (map-set weekly-certifications
      { certification-id: certification-id }
      (merge certification {
        status: "paid",
        payment-amount: payment-amount,
        payment-date: (some block-height)
      })
    )

    ;; Update claim weeks paid
    (map-set unemployment-claims
      { claim-id: (get claim-id certification) }
      (merge claim { weeks-paid: (+ (get weeks-paid claim) u1) })
    )

    ;; Deduct from benefits fund
    (var-set benefits-fund (- (var-get benefits-fund) payment-amount))

    (ok payment-amount)
  )
)

;; Private Helper Functions
(define-private (calculate-payment-amount (weekly-benefit uint) (earnings uint))
  (if (>= earnings weekly-benefit)
    u0
    (- weekly-benefit earnings)
  )
)

;; Read-only Functions
(define-read-only (get-unemployment-claim (claim-id uint))
  (map-get? unemployment-claims { claim-id: claim-id })
)

(define-read-only (get-weekly-certification (certification-id uint))
  (map-get? weekly-certifications { certification-id: certification-id })
)

(define-read-only (get-claimant-eligibility (claimant principal))
  (map-get? claimant-eligibility { claimant: claimant })
)

(define-read-only (get-benefits-fund-balance)
  (var-get benefits-fund)
)

(define-read-only (get-total-claims)
  (- (var-get next-claim-id) u1)
)

(define-read-only (get-total-certifications)
  (- (var-get next-certification-id) u1)
)
