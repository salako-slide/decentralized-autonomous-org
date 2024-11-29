;; title: Bitcoin-Powered DAO
;; version: 1.0.0
;; summary: A decentralized autonomous organization (DAO) powered by Bitcoin, enabling members to stake tokens, create and vote on proposals, and manage a treasury.
;; description: 
;; This smart contract implements a Bitcoin-powered DAO where members can join, leave, stake tokens, and participate in governance by creating and voting on proposals. The contract manages a treasury and supports cross-DAO collaborations. Key features include:
;; - Membership management: join, leave, stake, and unstake tokens.
;; - Proposal management: create, vote, and execute proposals.
;; - Treasury management: donate to the treasury and manage funds.
;; - Cross-DAO collaboration: propose and accept collaborations with other DAOs.
;; - Reputation system: members earn reputation for participating in governance activities.

;; traits
;;

;; token definitions
;;

;; constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-ALREADY-MEMBER (err u101))
(define-constant ERR-NOT-MEMBER (err u102))
(define-constant ERR-INVALID-PROPOSAL (err u103))
(define-constant ERR-PROPOSAL-EXPIRED (err u104))
(define-constant ERR-ALREADY-VOTED (err u105))
(define-constant ERR-INSUFFICIENT-FUNDS (err u106))
(define-constant ERR-INVALID-AMOUNT (err u107))

;; data vars
(define-data-var total-members uint u0)
(define-data-var total-proposals uint u0)
(define-data-var treasury-balance uint u0)

;; data maps
(define-map members principal 
  {
    reputation: uint,
    stake: uint,
    last-interaction: uint
  }
)

(define-map proposals uint 
  {
    creator: principal,
    title: (string-ascii 50),
    description: (string-utf8 500),
    amount: uint,
    yes-votes: uint,
    no-votes: uint,
    status: (string-ascii 10),
    created-at: uint,
    expires-at: uint
  }
)

(define-map votes {proposal-id: uint, voter: principal} bool)

(define-map collaborations uint 
  {
    partner-dao: principal,
    proposal-id: uint,
    status: (string-ascii 10)
  }
)

;; public functions

;; Membership management
(define-public (join-dao)
  (let (
    (caller tx-sender)
  )
    (asserts! (not (is-member caller)) ERR-ALREADY-MEMBER)
    (map-set members caller {reputation: u1, stake: u0, last-interaction: block-height})
    (var-set total-members (+ (var-get total-members) u1))
    (ok true)
  )
)

(define-public (leave-dao)
  (let (
    (caller tx-sender)
  )
    (asserts! (is-member caller) ERR-NOT-MEMBER)
    (map-delete members caller)
    (var-set total-members (- (var-get total-members) u1))
    (ok true)
  )
)

(define-public (stake-tokens (amount uint))
  (let (
    (caller tx-sender)
  )
    (asserts! (is-member caller) ERR-NOT-MEMBER)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (try! (stx-transfer? amount caller (as-contract tx-sender)))
    (match (map-get? members caller)
      member-data 
      (let (
        (new-stake (+ (get stake member-data) amount))
        (updated-data (merge member-data {stake: new-stake, last-interaction: block-height}))
      )
        (map-set members caller updated-data)
        (var-set treasury-balance (+ (var-get treasury-balance) amount))
        (ok new-stake)
      )
      ERR-NOT-MEMBER
    )
  )
)

(define-public (unstake-tokens (amount uint))
  (let (
    (caller tx-sender)
  )
    (asserts! (is-member caller) ERR-NOT-MEMBER)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (match (map-get? members caller)
      member-data 
      (let (
        (current-stake (get stake member-data))
      )
        (asserts! (>= current-stake amount) ERR-INSUFFICIENT-FUNDS)
        (try! (as-contract (stx-transfer? amount tx-sender caller)))
        (let (
          (new-stake (- current-stake amount))
          (updated-data (merge member-data {stake: new-stake, last-interaction: block-height}))
        )
          (map-set members caller updated-data)
          (var-set treasury-balance (- (var-get treasury-balance) amount))
          (ok new-stake)
        )
      )
      ERR-NOT-MEMBER
    )
  )
)

;; Proposal management
(define-public (create-proposal (title (string-ascii 50)) (description (string-utf8 500)) (amount uint))
  (let (
    (caller tx-sender)
    (proposal-id (+ (var-get total-proposals) u1))
  )
    (asserts! (is-member caller) ERR-NOT-MEMBER)
    (asserts! (>= (var-get treasury-balance) amount) ERR-INSUFFICIENT-FUNDS)
    (asserts! (> (len title) u0) ERR-INVALID-PROPOSAL)
    (asserts! (> (len description) u0) ERR-INVALID-PROPOSAL)
    (map-set proposals proposal-id
      {
        creator: caller,
        title: title,
        description: description,
        amount: amount,
        yes-votes: u0,
        no-votes: u0,
        status: "active",
        created-at: block-height,
        expires-at: (+ block-height u1440) ;; Proposal expires after 1440 blocks (approx. 10 days)
      }
    )
    (var-set total-proposals proposal-id)
    (try! (update-member-reputation caller 1)) ;; Increase reputation for creating a proposal
    (ok proposal-id)
  )
)

(define-public (vote-on-proposal (proposal-id uint) (vote bool))
  (let (
    (caller tx-sender)
  )
    (asserts! (is-member caller) ERR-NOT-MEMBER)
    (asserts! (is-active-proposal proposal-id) ERR-INVALID-PROPOSAL)
    (asserts! (not (default-to false (map-get? votes {proposal-id: proposal-id, voter: caller}))) ERR-ALREADY-VOTED)
    
    (let (
      (voting-power (calculate-voting-power caller))
      (proposal (unwrap! (map-get? proposals proposal-id) ERR-INVALID-PROPOSAL))
    )
      (if vote
        (map-set proposals proposal-id (merge proposal {yes-votes: (+ (get yes-votes proposal) voting-power)}))
        (map-set proposals proposal-id (merge proposal {no-votes: (+ (get no-votes proposal) voting-power)}))
      )
      (map-set votes {proposal-id: proposal-id, voter: caller} true)
      (try! (update-member-reputation caller 1)) ;; Increase reputation for voting
      (ok true)
    )
  )
)

(define-public (execute-proposal (proposal-id uint))
  (let (
    (caller tx-sender)
  )
    (asserts! (is-member caller) ERR-NOT-MEMBER)
    (asserts! (is-valid-proposal-id proposal-id) ERR-INVALID-PROPOSAL)
    (match (map-get? proposals proposal-id)
      proposal 
      (begin
        (asserts! (>= block-height (get expires-at proposal)) ERR-PROPOSAL-EXPIRED)
        (asserts! (is-eq (get status proposal) "active") ERR-INVALID-PROPOSAL)
        (let (
          (yes-votes (get yes-votes proposal))
          (no-votes (get no-votes proposal))
          (amount (get amount proposal))
        )
          (if (> yes-votes no-votes)
            (begin
              (try! (as-contract (stx-transfer? amount tx-sender (get creator proposal))))
              (var-set treasury-balance (- (var-get treasury-balance) amount))
              ;; Add additional validation before setting status
              (asserts! (is-valid-proposal-id proposal-id) ERR-INVALID-PROPOSAL)
              (map-set proposals proposal-id (merge proposal {status: "executed"}))
              (try! (update-member-reputation (get creator proposal) 5))
              (ok true)
            )
            (begin
              ;; Add additional validation before setting status
              (asserts! (is-valid-proposal-id proposal-id) ERR-INVALID-PROPOSAL)
              (map-set proposals proposal-id (merge proposal {status: "rejected"}))
              (ok false)
            )
          )
        )
      )
      ERR-INVALID-PROPOSAL
    )
  )
)

;; Treasury management
(define-public (donate-to-treasury (amount uint))
  (let (
    (caller tx-sender)
  )
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (try! (stx-transfer? amount caller (as-contract tx-sender)))
    (var-set treasury-balance (+ (var-get treasury-balance) amount))
    (if (is-member caller)
      (begin
        (try! (update-member-reputation caller 2)) ;; Increase reputation for donating
        (ok true)
      )
      (ok true)
    )
  )
)

;; Cross-DAO collaboration
(define-public (propose-collaboration (partner-dao principal) (proposal-id uint))
  (let (
    (caller tx-sender)
    (collaboration-id (+ (var-get total-proposals) u1))
  )
    (asserts! (is-member caller) ERR-NOT-MEMBER)
    (asserts! (is-active-proposal proposal-id) ERR-INVALID-PROPOSAL)
    (asserts! (not (is-eq partner-dao caller)) ERR-INVALID-PROPOSAL)
    (map-set collaborations collaboration-id
      {
        partner-dao: partner-dao,
        proposal-id: proposal-id,
        status: "proposed"
      }
    )
    (var-set total-proposals collaboration-id)
    (ok collaboration-id)
  )
)

(define-public (accept-collaboration (collaboration-id uint))
  (let (
    (caller tx-sender)
  )
    (asserts! (is-valid-collaboration-id collaboration-id) ERR-INVALID-PROPOSAL)
    (match (map-get? collaborations collaboration-id)
      collaboration 
      (begin
        (asserts! (is-eq caller (get partner-dao collaboration)) ERR-NOT-AUTHORIZED)
        (asserts! (is-eq (get status collaboration) "proposed") ERR-INVALID-PROPOSAL)
        ;; Add additional validation before setting status
        (asserts! (is-valid-collaboration-id collaboration-id) ERR-INVALID-PROPOSAL)
        (map-set collaborations collaboration-id (merge collaboration {status: "accepted"}))
        (ok true)
      )
      ERR-INVALID-PROPOSAL
    )
  )
)

;; read only functions
(define-read-only (get-treasury-balance)
  (ok (var-get treasury-balance))
)

(define-read-only (get-member-reputation (user principal))
  (match (map-get? members user)
    member-data (ok (get reputation member-data))
    ERR-NOT-MEMBER
  )
)

(define-read-only (get-proposal (proposal-id uint))
  (ok (unwrap! (map-get? proposals proposal-id) ERR-INVALID-PROPOSAL))
)

(define-read-only (get-member (user principal))
  (ok (unwrap! (map-get? members user) ERR-NOT-MEMBER))
)

(define-read-only (get-total-members)
  (ok (var-get total-members))
)

(define-read-only (get-total-proposals)
  (ok (var-get total-proposals))
)

;; private functions
(define-private (is-member (user principal))
  (match (map-get? members user)
    member-data true
    false
  )
)

(define-private (is-active-proposal (proposal-id uint))
  (match (map-get? proposals proposal-id)
    proposal (and 
      (< block-height (get expires-at proposal))
      (is-eq (get status proposal) "active")
    )
    false
  )
)