;; Microfinance Lending Platform Smart Contract
;; Provides small loans to underserved communities with social impact tracking

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-authorized (err u101))
(define-constant err-application-not-found (err u102))
(define-constant err-loan-not-found (err u103))
(define-constant err-invalid-amount (err u104))
(define-constant err-insufficient-funds (err u105))
(define-constant err-loan-not-active (err u106))
(define-constant err-payment-too-large (err u107))
(define-constant err-borrower-exists (err u108))
(define-constant err-invalid-term (err u109))
(define-constant err-loan-already-approved (err u110))
(define-constant err-loan-not-approved (err u111))
(define-constant err-borrower-not-verified (err u112))
(define-constant err-insufficient-vouches (err u113))
(define-constant min-loan-amount u50000000) ;; 50 STX minimum
(define-constant max-loan-amount u5000000000) ;; 5000 STX maximum
(define-constant min-loan-term u30) ;; 30 days minimum
(define-constant max-loan-term u365) ;; 365 days maximum
(define-constant platform-fee-rate u250) ;; 2.5% platform fee

;; Data structures
(define-map borrowers principal {
    name: (string-ascii 100),
    verified: bool,
    credit-score: uint,
    total-borrowed: uint,
    total-repaid: uint,
    active-loans: uint,
    default-count: uint,
    registration-date: uint,
    community-vouches: uint,
    impact-score: uint
})

(define-map loan-applications uint {
    borrower: principal,
    amount: uint,
    purpose: (string-ascii 200),
    term-days: uint,
    interest-rate: uint,
    status: (string-ascii 20), ;; "pending", "approved", "rejected", "disbursed"
    application-date: uint,
    risk-assessment: uint,
    community-support: uint,
    impact-category: (string-ascii 50)
})

(define-map loans uint {
    borrower: principal,
    principal-amount: uint,
    interest-rate: uint,
    term-days: uint,
    amount-repaid: uint,
    status: (string-ascii 20), ;; "active", "completed", "defaulted", "restructured"
    disbursement-date: uint,
    due-date: uint,
    monthly-payment: uint,
    late-payment-count: uint,
    purpose: (string-ascii 200)
})

(define-map payments { loan-id: uint, payment-id: uint } {
    amount: uint,
    payment-date: uint,
    payment-type: (string-ascii 20), ;; "regular", "early", "late", "penalty"
    principal-portion: uint,
    interest-portion: uint,
    remaining-balance: uint
})

(define-map vouches { borrower: principal, voucher: principal } {
    amount: uint,
    vouch-date: uint,
    relationship: (string-ascii 50),
    active: bool
})

(define-map impact-records uint {
    loan-id: uint,
    category: (string-ascii 50),
    metric-type: (string-ascii 50),
    value: uint,
    measurement-date: uint,
    notes: (string-ascii 200)
})

(define-map staff-members principal {
    role: (string-ascii 30), ;; "loan-officer", "impact-assessor", "admin"
    permissions: uint,
    hire-date: uint,
    active: bool
})

;; Contract state variables
(define-data-var next-application-id uint u1)
(define-data-var next-loan-id uint u1)
(define-data-var next-payment-id uint u1)
(define-data-var next-impact-record-id uint u1)
(define-data-var total-loans-disbursed uint u0)
(define-data-var total-amount-disbursed uint u0)
(define-data-var total-amount-repaid uint u0)
(define-data-var total-borrowers uint u0)
(define-data-var active-loans-count uint u0)
(define-data-var default-rate uint u0)
(define-data-var platform-reserves uint u0)
(define-data-var interest-collected uint u0)

;; Authorization functions
(define-private (is-contract-owner)
    (is-eq tx-sender contract-owner))

(define-private (is-staff-member (member principal))
    (match (map-get? staff-members member)
        staff-data (get active staff-data)
        false
    )
)

(define-private (is-loan-officer (member principal))
    (match (map-get? staff-members member)
        staff-data (and 
            (get active staff-data)
            (or (is-eq (get role staff-data) "loan-officer") (is-eq (get role staff-data) "admin"))
        )
        false
    )
)

(define-private (validate-loan-amount (amount uint))
    (and (>= amount min-loan-amount) (<= amount max-loan-amount)))

(define-private (validate-loan-term (term uint))
    (and (>= term min-loan-term) (<= term max-loan-term)))

(define-private (calculate-monthly-payment (principal uint) (interest-rate uint) (term uint))
    (let (
        (monthly-rate (/ interest-rate u12))
        (payment-multiplier (/ (* monthly-rate u10000) u100))
    )
        (/ (* principal payment-multiplier) term)
    )
)

(define-private (calculate-platform-fee (amount uint))
    (/ (* amount platform-fee-rate) u10000))

;; Borrower management functions
(define-public (register-borrower (name (string-ascii 100)))
    (begin
        (asserts! (is-none (map-get? borrowers tx-sender)) err-borrower-exists)
        
        (map-set borrowers tx-sender {
            name: name,
            verified: false,
            credit-score: u500, ;; Starting credit score
            total-borrowed: u0,
            total-repaid: u0,
            active-loans: u0,
            default-count: u0,
            registration-date: block-height,
            community-vouches: u0,
            impact-score: u0
        })
        
        (var-set total-borrowers (+ (var-get total-borrowers) u1))
        
        (ok { borrower: tx-sender, registered: true })
    )
)

(define-public (verify-borrower (borrower principal))
    (begin
        (asserts! (is-staff-member tx-sender) err-not-authorized)
        
        (match (map-get? borrowers borrower)
            borrower-data
            (begin
                (map-set borrowers borrower
                    (merge borrower-data { verified: true })
                )
                (ok { borrower: borrower, verified: true })
            )
            err-application-not-found
        )
    )
)

(define-public (vouch-for-borrower (borrower principal) (amount uint) (relationship (string-ascii 50)))
    (begin
        (asserts! (> amount u0) err-invalid-amount)
        (asserts! (not (is-eq tx-sender borrower)) err-not-authorized)
        
        (map-set vouches { borrower: borrower, voucher: tx-sender } {
            amount: amount,
            vouch-date: block-height,
            relationship: relationship,
            active: true
        })
        
        ;; Update borrower's community vouch count
        (match (map-get? borrowers borrower)
            borrower-data
            (map-set borrowers borrower
                (merge borrower-data { 
                    community-vouches: (+ (get community-vouches borrower-data) u1)
                })
            )
            false
        )
        
        (ok { borrower: borrower, voucher: tx-sender, amount: amount })
    )
)

;; Loan application and approval functions
(define-public (apply-for-loan 
    (amount uint)
    (purpose (string-ascii 200))
    (term-days uint)
    (impact-category (string-ascii 50))
)
    (let (
        (application-id (var-get next-application-id))
    )
        (asserts! (validate-loan-amount amount) err-invalid-amount)
        (asserts! (validate-loan-term term-days) err-invalid-term)
        
        ;; Check if borrower is registered
        (match (map-get? borrowers tx-sender)
            borrower-data
            (begin
                (asserts! (get verified borrower-data) err-borrower-not-verified)
                
                (map-set loan-applications application-id {
                    borrower: tx-sender,
                    amount: amount,
                    purpose: purpose,
                    term-days: term-days,
                    interest-rate: u0, ;; To be set by loan officer
                    status: "pending",
                    application-date: block-height,
                    risk-assessment: (get credit-score borrower-data),
                    community-support: (get community-vouches borrower-data),
                    impact-category: impact-category
                })
                
                (var-set next-application-id (+ application-id u1))
                
                (ok { application-id: application-id, borrower: tx-sender, amount: amount })
            )
            err-borrower-not-verified
        )
    )
)

(define-public (approve-loan (application-id uint) (interest-rate uint))
    (begin
        (asserts! (is-loan-officer tx-sender) err-not-authorized)
        
        (match (map-get? loan-applications application-id)
            app-data
            (let (
                (borrower (get borrower app-data))
                (amount (get amount app-data))
            )
                (asserts! (is-eq (get status app-data) "pending") err-loan-already-approved)
                (asserts! (>= (get community-support app-data) u2) err-insufficient-vouches)
                
                (map-set loan-applications application-id
                    (merge app-data { 
                        status: "approved",
                        interest-rate: interest-rate
                    })
                )
                
                (ok { application-id: application-id, approved: true, interest-rate: interest-rate })
            )
            err-application-not-found
        )
    )
)

(define-public (disburse-loan (application-id uint))
    (begin
        (asserts! (is-loan-officer tx-sender) err-not-authorized)
        
        (match (map-get? loan-applications application-id)
            app-data
            (let (
                (loan-id (var-get next-loan-id))
                (borrower (get borrower app-data))
                (amount (get amount app-data))
                (interest-rate (get interest-rate app-data))
                (term-days (get term-days app-data))
                (platform-fee (calculate-platform-fee amount))
                (disbursement-amount (- amount platform-fee))
                (monthly-payment (calculate-monthly-payment amount interest-rate term-days))
                (due-date (+ block-height term-days))
            )
                (asserts! (is-eq (get status app-data) "approved") err-loan-not-approved)
                (asserts! (>= (var-get platform-reserves) amount) err-insufficient-funds)
                
                ;; Transfer loan amount to borrower
                (try! (as-contract (stx-transfer? disbursement-amount tx-sender borrower)))
                
                ;; Create loan record
                (map-set loans loan-id {
                    borrower: borrower,
                    principal-amount: amount,
                    interest-rate: interest-rate,
                    term-days: term-days,
                    amount-repaid: u0,
                    status: "active",
                    disbursement-date: block-height,
                    due-date: due-date,
                    monthly-payment: monthly-payment,
                    late-payment-count: u0,
                    purpose: (get purpose app-data)
                })
                
                ;; Update application status
                (map-set loan-applications application-id
                    (merge app-data { status: "disbursed" })
                )
                
                ;; Update borrower record
                (match (map-get? borrowers borrower)
                    borrower-data
                    (map-set borrowers borrower
                        (merge borrower-data {
                            total-borrowed: (+ (get total-borrowed borrower-data) amount),
                            active-loans: (+ (get active-loans borrower-data) u1)
                        })
                    )
                    false
                )
                
                ;; Update contract state
                (var-set next-loan-id (+ loan-id u1))
                (var-set total-loans-disbursed (+ (var-get total-loans-disbursed) u1))
                (var-set total-amount-disbursed (+ (var-get total-amount-disbursed) amount))
                (var-set active-loans-count (+ (var-get active-loans-count) u1))
                (var-set platform-reserves (- (var-get platform-reserves) amount))
                
                (ok { loan-id: loan-id, amount: disbursement-amount, borrower: borrower })
            )
            err-application-not-found
        )
    )
)

;; Repayment functions
(define-public (make-payment (loan-id uint) (payment-amount uint))
    (begin
        (asserts! (> payment-amount u0) err-invalid-amount)
        
        (match (map-get? loans loan-id)
            loan-data
            (let (
                (borrower (get borrower loan-data))
                (principal-amount (get principal-amount loan-data))
                (amount-repaid (get amount-repaid loan-data))
                (remaining-balance (- principal-amount amount-repaid))
                (payment-id (var-get next-payment-id))
            )
                (asserts! (is-eq tx-sender borrower) err-not-authorized)
                (asserts! (is-eq (get status loan-data) "active") err-loan-not-active)
                (asserts! (<= payment-amount remaining-balance) err-payment-too-large)
                
                ;; Process payment
                (try! (stx-transfer? payment-amount tx-sender (as-contract tx-sender)))
                
                ;; Record payment
                (map-set payments { loan-id: loan-id, payment-id: payment-id } {
                    amount: payment-amount,
                    payment-date: block-height,
                    payment-type: "regular",
                    principal-portion: payment-amount,
                    interest-portion: u0,
                    remaining-balance: (- remaining-balance payment-amount)
                })
                
                ;; Update loan record
                (let (
                    (new-amount-repaid (+ amount-repaid payment-amount))
                    (is-completed (is-eq new-amount-repaid principal-amount))
                )
                    (map-set loans loan-id
                        (merge loan-data {
                            amount-repaid: new-amount-repaid,
                            status: (if is-completed "completed" "active")
                        })
                    )
                    
                    ;; Update borrower record
                    (match (map-get? borrowers borrower)
                        borrower-data
                        (map-set borrowers borrower
                            (merge borrower-data {
                                total-repaid: (+ (get total-repaid borrower-data) payment-amount),
                                active-loans: (if is-completed 
                                    (- (get active-loans borrower-data) u1)
                                    (get active-loans borrower-data)
                                ),
                                credit-score: (if is-completed
                                    (+ (get credit-score borrower-data) u50)
                                    (get credit-score borrower-data)
                                )
                            })
                        )
                        false
                    )
                    
                    ;; Update contract state
                    (var-set next-payment-id (+ payment-id u1))
                    (var-set total-amount-repaid (+ (var-get total-amount-repaid) payment-amount))
                    (var-set platform-reserves (+ (var-get platform-reserves) payment-amount))
                    
                    (if is-completed
                        (var-set active-loans-count (- (var-get active-loans-count) u1))
                        true
                    )
                    
                    (ok { 
                        loan-id: loan-id, 
                        payment-amount: payment-amount, 
                        remaining-balance: (- remaining-balance payment-amount),
                        loan-completed: is-completed
                    })
                )
            )
            err-loan-not-found
        )
    )
)

;; Impact tracking functions
(define-public (record-impact (loan-id uint) (category (string-ascii 50)) (metric-type (string-ascii 50)) (value uint) (notes (string-ascii 200)))
    (let (
        (record-id (var-get next-impact-record-id))
    )
        (asserts! (or (is-staff-member tx-sender) (is-loan-borrower loan-id tx-sender)) err-not-authorized)
        (asserts! (is-some (map-get? loans loan-id)) err-loan-not-found)
        
        (map-set impact-records record-id {
            loan-id: loan-id,
            category: category,
            metric-type: metric-type,
            value: value,
            measurement-date: block-height,
            notes: notes
        })
        
        (var-set next-impact-record-id (+ record-id u1))
        
        (ok { record-id: record-id, loan-id: loan-id, category: category })
    )
)

;; Staff management functions
(define-public (add-staff-member (member principal) (role (string-ascii 30)) (permissions uint))
    (begin
        (asserts! (is-contract-owner) err-owner-only)
        
        (map-set staff-members member {
            role: role,
            permissions: permissions,
            hire-date: block-height,
            active: true
        })
        
        (ok { member: member, role: role, active: true })
    )
)

;; Administrative functions
(define-public (deposit-reserves (amount uint))
    (begin
        (asserts! (is-contract-owner) err-owner-only)
        (asserts! (> amount u0) err-invalid-amount)
        
        (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
        (var-set platform-reserves (+ (var-get platform-reserves) amount))
        
        (ok { deposited: amount, total-reserves: (var-get platform-reserves) })
    )
)

;; Helper functions
(define-private (is-loan-borrower (loan-id uint) (user principal))
    (match (map-get? loans loan-id)
        loan-data (is-eq (get borrower loan-data) user)
        false
    )
)

;; Read-only functions
(define-read-only (get-borrower-info (borrower principal))
    (map-get? borrowers borrower)
)

(define-read-only (get-loan-application (application-id uint))
    (map-get? loan-applications application-id)
)

(define-read-only (get-loan-details (loan-id uint))
    (map-get? loans loan-id)
)

(define-read-only (get-payment-record (loan-id uint) (payment-id uint))
    (map-get? payments { loan-id: loan-id, payment-id: payment-id })
)

(define-read-only (get-impact-record (record-id uint))
    (map-get? impact-records record-id)
)

(define-read-only (get-platform-stats)
    {
        total-loans-disbursed: (var-get total-loans-disbursed),
        total-amount-disbursed: (var-get total-amount-disbursed),
        total-amount-repaid: (var-get total-amount-repaid),
        total-borrowers: (var-get total-borrowers),
        active-loans-count: (var-get active-loans-count),
        platform-reserves: (var-get platform-reserves),
        default-rate: (var-get default-rate)
    }
)

(define-read-only (calculate-loan-payment (amount uint) (interest-rate uint) (term uint))
    (calculate-monthly-payment amount interest-rate term)
)


;; title: micro-loans
;; version:
;; summary:
;; description:

;; traits
;;

;; token definitions
;;

;; constants
;;

;; data vars
;;

;; data maps
;;

;; public functions
;;

;; read only functions
;;

;; private functions
;;

