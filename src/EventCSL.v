Require Export MemClass.
Require Export Pred.
Require Export Word.
Require Export SepAuto.
Require Export Hlist.
Require Export Variables.
Require Import Omega.
Require Import Star.
Require Import List.
Import List.ListNotations.
Local Open Scope list.

(* defined in Prog. which we don't want to import here *)
Definition addrlen := 64.
Definition valulen := 4096.
Notation addr := (word addrlen).
Notation valu := (word valulen).

Global Set Implicit Arguments.

Definition pred_in AT AEQ V (F: @pred AT AEQ V) m := F m.

Notation "m '|=' F" :=
  (pred_in F%pred m) (at level 30, F at level 40) : mem_judgement_scope.

Delimit Scope mem_judgement_scope with judgement.

Section AsyncDiskWrites.

  Inductive valuset : Set :=
  | Valuset (last:valu) (pending:list valu).

  Definition buffer_valu (vs:valuset) v :=
    match vs with
    | Valuset last pending => Valuset v (last::pending)
    end.

  Definition latest_valu (vs:valuset) :=
    let 'Valuset last _ := vs in last.

  Definition pending_valus (vs:valuset) :=
    let 'Valuset _ pending := vs in pending.

  Definition synced (vs:valuset) :=
    let 'Valuset last _ := vs in Valuset last nil.

End AsyncDiskWrites.

Hint Immediate (Valuset $0 nil).
Hint Immediate (Valuset $0 nil, @None ID).

Definition ID := nat.

Definition wr_set : Type := valu * option ID.

(* a disk state *)
Notation DISK := (@mem addr (@weq addrlen) (const wr_set)).

(* a disk predicate *)
Notation DISK_PRED := (@pred addr (@weq addrlen) (const wr_set)).

Section EventCSL.
  Set Default Proof Using "Type".

  (** The memory is a heterogenously typed list where element types
      are given by Mcontents. *)
  Variable Mcontents:list Type.
  (** The type of the program's memory. *)
  Definition M := @hlist Type (fun T:Type => T) Mcontents.


  (** Programs can manipulate ghost state of an hlist where element types
      are given by Scontents *)
  Variable Scontents:list Type.
  Definition S := @hlist Type (fun T:Type => T) Scontents.

  (** Our programs will return values of type T *)
  Variable T:Type.

  (** Define the transition system for the semantics.
      The semantics will reject transitions that do not obey these rules. *)
  Definition Relation := S -> S -> Prop.
  Variable StateR : ID -> Relation.
  Definition Invariant := M -> S -> DISK_PRED.
  Variable StateI : Invariant.

  CoInductive prog :=
  | StartRead (a: addr) (rx: unit -> prog)
  | FinishRead (a: addr) (rx: valu -> prog)
  | Write (a: addr) (v: valu) (rx: unit -> prog)
  | Sync (a: addr) (rx: unit -> prog)
  | Get t (v: var Mcontents t) (rx: t -> prog)
  | Assgn t (v: var Mcontents t) (val:t) (rx: unit -> prog)
  | GetTID (rx: ID -> prog)
  | Yield (wchan: addr) (rx: unit -> prog)
  | Wakeup (wchan: addr) (rx: unit -> prog)
  | GhostUpdate (up: S -> S) (rx: unit -> prog)
  | Done (v: T).

  Ltac inv_prog :=
    match goal with
    | [ H: @eq prog _ _ |- _ ] =>
      inversion H
    end.

  Implicit Type d : DISK.
  Implicit Type m : M.
  Implicit Type s : S.
  Implicit Type p : prog.

  Definition state := (DISK * M * S * S)%type.

  Reserved Notation "tid ':-' p '/' st '==>' p' '/' st'"
           (at level 40, p at next level, p' at next level).

  Definition othersR (stateR:ID -> Relation) tid : Relation :=
    fun s s' =>
      exists tid', tid <> tid' /\
              stateR tid' s s'.

  Definition anyR (stateR : ID -> Relation) : Relation :=
    fun s s' => exists tid, stateR tid s s'.

  (* StateR' tid is a valid transition for someone other than tid *)
  Definition StateR' : ID -> Relation := othersR StateR.

  (* StateRany is a valid transition for any tid *)
  Definition StateRany : Relation := anyR StateR.

  Lemma StateR'_any : forall tid s1 s2,
    StateR' tid s1 s2 -> StateRany s1 s2.
  Proof.
    unfold StateR', StateRany, othersR, anyR. intuition deex. eauto.
  Qed.

  Inductive step (tid:ID) : forall st p st' p', Prop :=
  | StepStartRead : forall d m s0 s v
                      a rx,
      d a = Some (v, None) ->
      let d' := upd d a (v, Some tid) in
      tid :- StartRead a rx / (d, m, s0, s) ==>
        rx tt / (d', m, s0, s)
  | StepFinishRead : forall d m s0 s a rx v,
      d a = Some (v, Some tid) ->
      let d' := upd d a (v, None) in
      tid :- FinishRead a rx / (d, m, s0, s) ==>
          rx v / (d', m, s0, s)
  | StepWrite : forall d m s0 s a rx v0 v',
      d a = Some (v0, None) ->
      let d' := upd d a (v', None) in
      tid :- Write a v' rx / (d, m, s0, s) ==>
          rx tt / (d', m, s0, s)
  | StepYield : forall d m s0 s s' m' d' wchan rx,
      StateI m s d ->
      StateI m' s' d' ->
      StateR tid s0 s ->
      star (StateR' tid) s s' ->
      tid :- Yield wchan rx / (d, m, s0, s) ==>
          rx tt / (d', m', s', s')
  | StepWakeup : forall d m s0 s wchan rx,
      tid :- Wakeup wchan rx / (d, m, s0, s) ==>
          rx tt / (d, m, s0, s)
  | StepGhostUpdate : forall d m s0 s up rx,
      let s' := up s in
      tid :- GhostUpdate up rx / (d, m, s0, s) ==>
          rx tt / (d, m, s0, s')
  | StepGetTID : forall st rx,
      tid :- GetTID rx / st ==> rx tid / st
  | StepGet : forall d m s s0 t (v: var Mcontents t) rx,
      tid :- Get v rx / (d, m, s0, s) ==> rx (get v m) / (d, m, s0, s)
  | StepAssgn : forall d m s s0 t (v: var Mcontents t) val rx,
      let m' := set v val m in
      tid :- Assgn v val rx / (d, m, s0, s) ==> rx tt / (d, m', s0, s)
  where "tid ':-' p '/' st '==>' p' '/' st'" := (step tid st p st' p').

  Inductive fail_step (tid:ID) : prog -> state -> Prop :=
  | FailStepStartRead : forall a d m s0 s rx,
      d a = None ->
      fail_step tid (StartRead a rx) (d, m, s0, s)
  | FailStepStartReadConflict : forall a vs tid' d m s0 s rx,
      tid' <> tid ->
      d a = Some (vs, Some tid') ->
      fail_step tid (StartRead a rx) (d, m, s0, s)
  | FailStepFinishRead : forall a vs d m s0 s rx,
      d a = Some (vs, None) ->
      fail_step tid (FinishRead a rx) (d, m, s0, s)
  | FailStepFinishConflict : forall a vs tid' d m s0 s rx,
      tid' <> tid ->
      d a = Some (vs, Some tid') ->
      fail_step tid (FinishRead a rx) (d, m, s0, s)
  | FailStepWriteMissing : forall a v d m s0 s rx,
      d a = None ->
      fail_step tid (Write a v rx) (d, m, s0, s)
  | FailStepYield : forall d m s0 s wchan rx,
      (~StateI m s d) ->
      fail_step tid (Yield wchan rx) (d, m, s0, s).

  Hint Constructors step fail_step.

  Theorem fail_step_consistent : forall tid p d m s0 s
                                   p' st',
      step tid (d, m, s0, s) p st' p' ->
      fail_step tid p (d, m, s0, s) ->
      False.
  Proof.
    inversion 1; inversion 1; congruence.
  Qed.

  Ltac inv_step :=
    match goal with
    | [ H: step _ _ _ _ _ |- _ ] =>
      inversion H; subst
    end.

  Inductive outcome :=
  | Failed
  | Crashed d
  | Finished d (v:T).

  (** yieldProg p holds when p begins by yielding to the scheduler.

  This might be needed to define executions such that a crash in the middle of
  a yield results in a state consistent with the lock discipline, but I don't
  believe this is important since some other thread must have crashed during
  execution and we can use its crash condition. *)
  Inductive yieldProg : forall p, Prop :=
  | YieldProgYield : forall wchan rx,
    yieldProg (Yield wchan rx).

  Inductive exec tid : forall st p (out:outcome), Prop :=
  | ExecStep : forall st p st' p' out,
      tid :- p / st ==> p' / st' ->
      exec tid st' p' out ->
      exec tid st p out
  | ExecFail : forall st p,
      fail_step tid p st ->
      exec tid st p Failed
  | ExecDone : forall d m s0 s v,
      exec tid (d, m, s0, s) (Done v) (Finished d v).

  Hint Constructors exec.

  Section TwoStepExecution.

  Definition exec_ind2
                     (tid : ID)
                     (P : DISK * M * S * S -> prog -> outcome -> Prop)
                     (f : forall (st  : DISK * M * S * S) (p  : prog)
                                 (st' : DISK * M * S * S) (p' : prog)
                                 (out : outcome),
                          tid :- p / st ==> p' / st' ->
                          exec tid st' p' out ->
                          ((exists v, p' = Done v) \/
                           fail_step tid p' st') ->
                          P st' p' out ->
                          P st p out)
                     (g : forall (st   : DISK * M * S * S) (p   : prog)
                                 (st'  : DISK * M * S * S) (p'  : prog)
                                 (st'' : DISK * M * S * S) (p'' : prog)
                                 (out : outcome),
                          tid :- p / st ==> p' / st' ->
                          tid :- p' / st' ==> p'' / st'' ->
                          exec tid st'' p'' out ->
                          P st'' p'' out ->
                          P st p out)
                     (f0 : forall (st : state) (p : prog),
                           fail_step tid p st ->
                           P st p Failed)
                     (f1 : forall (d : DISK) (m : M) (s0 s : S) (v : T),
                           P (d, m, s0, s) (Done v) (Finished d v))
                     (st : DISK * M * S * S)
                     (p : prog)
                     (out : outcome)
                     (e : exec tid st p out) : (P st p out).

    refine ((fix exec_ind2
                     (st : DISK * M * S * S)
                     (p : prog)
                     (out : outcome)
                     (e : exec tid st p out) {struct e} : (P st p out) := _) st p out e).
    destruct e.

    - destruct e.
      + eapply g; eauto.
      + eapply f; eauto.
      + eapply f; eauto.
    - eauto.
    - eauto.
  Defined.

  Inductive exec2 tid : forall st p (out:outcome), Prop :=
  | Exec2Step : forall st p st' p' st'' p'' out,
      tid :- p / st ==> p' / st' ->
      tid :- p' / st' ==> p'' / st'' ->
      exec2 tid st'' p'' out ->
      exec2 tid st p out
  | Exec2Fail : forall st p,
      fail_step tid p st ->
      exec2 tid st p Failed
  | Exec2StepFail : forall st p st' p',
      tid :- p / st ==> p' / st' ->
      fail_step tid p' st' ->
      exec2 tid st p Failed
  | Exec2Done : forall d m s0 s v,
      exec2 tid (d, m, s0, s) (Done v) (Finished d v)
  | Exec2StepDone : forall st p d' m' s0' s' v,
      tid :- p / st ==> Done v / (d', m', s0', s') ->
      exec2 tid st p (Finished d' v).

  Hint Constructors exec2.

  Theorem exec2_imp_exec : forall tid st p out,
      exec2 tid st p out ->
      exec tid st p out.
  Proof.
    induction 1; eauto.
  Qed.

  Theorem exec_imp_exec2 : forall tid st p out,
      exec tid st p out ->
      exec2 tid st p out.
  Proof.
    induction 1; subst; eauto.
    inversion H0; subst; eauto.
  Admitted.

  Theorem exec_equiv_exec2 : forall tid st p out,
      exec tid st p out <->
      exec2 tid st p out.
  Proof.
    split; auto using exec2_imp_exec, exec_imp_exec2.
  Qed.

  End TwoStepExecution.

  (* clear up dependent equalities produced by inverting fail_step *)
  Ltac sigT_eq :=
    match goal with
    | [ H: @eq (sigT _) _ _ |- _ ] =>
      apply ProofIrrelevance.ProofIrrelevanceTheory.EqdepTheory.inj_pair2 in H;
        subst
    end.

  Ltac inv_fail_step :=
    match goal with
    | [ H: context[fail_step] |- _ ] =>
      inversion H; subst;
      (* produce equalities from dependent equalities using proof
      irrelevance *)
      repeat sigT_eq;
      (* get rid of local definitions in context *)
      repeat match goal with
             | [ v := _ : _ |- _ ] => subst v
             end
    end.

  Ltac condition_failure :=
    intros; inv_fail_step; eauto; try congruence.

  Theorem start_read_failure : forall tid d m s0 s rx a v,
      fail_step tid (StartRead a rx) (d, m, s0, s) ->
      d a = Some (v, None) ->
      False.
  Proof.
    condition_failure.
  Qed.

  Theorem finish_read_failure : forall tid d m s0 s rx a v,
      fail_step tid (FinishRead a rx) (d, m, s0, s) ->
      d a = Some (v, Some tid) ->
      False.
  Proof.
    condition_failure.
  Qed.

  Theorem write_failure : forall tid d m s0 s rx a v vs0,
      fail_step tid (Write a v rx) (d, m, s0, s) ->
      d a = Some (vs0, None) ->
      False.
  Proof.
    condition_failure.
  Qed.

  Hint Resolve start_read_failure finish_read_failure write_failure.

  Definition donecond := T -> DISK_PRED.

  (** A Hoare double judgement: encodes a Crash Hoare Logic tuple via
  a precondition that accepts appropriate postconditions (donecond) and crash
  conditions. *)
  Definition valid tid (pre: donecond ->
        (* state: d, m, s0, s *)
        DISK -> M -> S -> S -> Prop) p : Prop :=
    forall d m s0 s done out,
      pre done d m s0 s ->
      exec tid (d, m, s0, s) p out ->
      (exists d' v,
        out = Finished d' v /\ done v d').

  (** Programs are written in continuation-passing style, where sequencing
  is simply function application. We wrap this sequencing in a function for
  automation purposes, so that we can recognize when logically instructions
  are being sequenced. B is a continuation, of the type (input -> prog), while
  A is the type of the whole expression, (output -> prog). *)
  Definition progseq (A B:Type) (p1 : B -> A) (p2: B) := p1 p2.

  Ltac inv_st :=
    match goal with
    | [ H : @eq state _ _ |- _ ] =>
      inversion H
    end.

  Ltac inv_tuple :=
    match goal with
    | [ H : (_, _, _, _) = (_, _, _, _) |- _ ] =>
      inversion H; subst
    end.

  Ltac ind_exec :=
    match goal with
    | [ H : exec _ ?st ?p _ |- _ ] =>
      remember st; remember p;
      induction H; subst;
      try (destruct st; inv_st);
      try inv_tuple;
      try inv_step;
      try inv_prog
    end.

  Ltac prove_rx :=
    match goal with
    | [ H: forall _, valid _ _ _ |- _ ] =>
      edestruct H; eauto
    end.

  Notation "tid |- {{ e1 .. e2 , | 'PRE' d m s0 s : pre | 'POST' d' m' s0' s' r : post }} p" :=
    (forall (rx: _ -> prog) (tid:ID),
        valid tid (fun done d m s0 s =>
                     (ex (fun e1 => .. (ex (fun e2 =>
                                           pre%judgement /\
                                           (forall ret_,
                                             valid tid (fun done_rx d' m' s0' s' =>
                                                      (fun r => post%judgement) ret_ /\
                                                      done_rx = done)
                                                   (rx ret_))
                                    )) .. ))
                  ) (p rx))
      (at level 0, p at level 60,
       e1 binder, e2 binder,
       d at level 0,
       d' at level 0,
       m at level 0,
       m' at level 0,
       s0 at level 0,
       s0' at level 0,
       s at level 0,
       s' at level 0,
       r at level 0,
       only parsing).

  (* extract the precondition of a valid statement into the hypotheses *)
  Ltac intros_pre :=
    unfold valid at 1; unfold pred_in; intros;
    repeat deex.

  (* simplify the postcondition obligation to its components *)
  Ltac simpl_post :=
    cbn; intuition;
      (* get rid of local definitions in context *)
      repeat match goal with
             | [ v := _ : _ |- _ ] => subst v
             end.

  Ltac learn_mem_val H m a v :=
      assert (m a = Some v);
      [ eapply ptsto_valid;
        pred_apply' H; cancel |].

  Ltac learn_some_addr :=
    match goal with
    | [ a: addr, H: ?P ?m |- _ ] =>
      match P with
      | context[(a |-> ?v)%pred] => learn_mem_val H m a v
      end
    end.

  Ltac match_contents :=
    match goal with
    | [ H: ?d ?a = Some ?v1, H': ?d ?a = Some ?v2 |- _ ] =>
      let H := fresh in
      assert (v1 = v2) as H by congruence;
        inversion H; subst;
      clear H'
    end.

  Ltac opcode_ok :=
    intros_pre; ind_exec;
    try match goal with
    | [ H: context[step] |- _ ] =>
      prove_rx; simpl_post
    | [ H: context[fail_step] |- _ ] =>
      try solve [ inversion H; congruence ];
        try match goal with
        | [ Ha: context[ptsto] |- _ ] =>
          apply ptsto_valid' in Ha
        end;
      exfalso
    end;
    try (learn_some_addr; match_contents);
    eauto 10.

  Hint Resolve ptsto_upd'.

  Theorem Write_ok : forall a v,
      tid |- {{ F v0,
             | PRE d m s0 s: d |= F * a |-> (v0, None)
             | POST d' m' s0' s' _: d' |= F * a |-> (v, None) /\
                                s0' = s0 /\
                                s' = s /\
                                m' = m
            }} Write a v.
  Proof.
    opcode_ok.
  Qed.

  Theorem StartRead_ok : forall a,
    tid |- {{ F v0,
           | PRE d m s0 s: d |= F * a |-> (v0, None)
           | POST d' m' s0' s' _: d' |= F * a |-> (v0, Some tid) /\
                                  s0' = s0 /\
                                  s' = s /\
                                  m' = m
          }} StartRead a.
  Proof.
    opcode_ok.
    assert (v = v0).
    eapply ptsto_valid' in H1.
    congruence.
    subst; eauto.
  Qed.

  Theorem FinishRead_ok : forall a,
      tid |- {{ F v,
             | PRE d m s0 s: d |= F * a |-> (v, Some tid)
             | POST d' m' s0' s' r: d' |= F * a |-> (v, None) /\
                                    s0' = s0 /\
                                    s' = s /\
                                    m' = m /\
                                    r = v
            }} FinishRead a.
  Proof.
    opcode_ok.
    assert (v = v0).
    eapply ptsto_valid' in H1.
    congruence.
    subst; eauto.
    eapply ptsto_valid' in H1.
    congruence.
  Qed.

  Theorem Get_ok : forall t (v: var _ t),
      tid |- {{ (_:unit),
             | PRE d m s0 s: True
             | POST d' m' s0' s' r: d' = d /\
                                    r = get v m /\
                                    m' = m /\
                                    s0' = s0 /\
                                    s' = s
            }} Get v.
  Proof.
    opcode_ok; repeat sigT_eq; auto.
  Qed.

  Theorem Assgn_ok : forall t (v: var _ t) val,
      tid |- {{ (_:unit),
             | PRE d m s0 s: True
             | POST d' m' s0' s' _: d' = d /\
                                    m' = set v val m /\
                                    s0' = s0 /\
                                    s' = s
            }} Assgn v val.
  Proof.
    opcode_ok; repeat sigT_eq; eauto.
  Qed.

  Theorem GetTID_ok :
    tid |- {{ (_:unit),
           | PRE d m s0 s: True
           | POST d' m' s0' s' r: d' = d /\
                                  m' = m /\
                                  s0' = s0 /\
                                  s' = s /\
                                  r = tid
          }} GetTID.
  Proof.
    opcode_ok.
  Qed.

  Theorem Yield_ok : forall wchan,
    tid |- {{ (_:unit),
           | PRE d m s0 s: d |= StateI m s /\
                           StateR tid s0 s
           | POST d' m' s0' s' _: d' |= StateI m' s' /\
                                  s0' = s' /\
                                  star (StateR' tid) s s'
    }} Yield wchan.
  Proof.
    opcode_ok.
  Qed.

  Theorem GhostUpdate_ok : forall up,
    tid |- {{ (_:unit),
           | PRE d m s0 s: True
           | POST d' m' s0' s' _: d' = d /\
                                  s0' = s0 /\
                                  s' = up s /\
                                  m' = m
          }} GhostUpdate up.
  Proof.
    opcode_ok.
  Qed.

  Theorem Wakeup_ok : forall a,
    tid |- {{ (_:unit),
           | PRE d m s0 s: True
           | POST d' m' s0' s' _: d' = d /\
                                  s0' = s0 /\
                                  s' = s /\
                                  m' = m
          }} Wakeup a.
  Proof.
    opcode_ok.
  Qed.

  Theorem pimpl_ok : forall tid (pre pre': _ -> _ -> _ ->  _ -> _ -> Prop) p,
      valid tid pre p ->
      (forall done d m s0 s, pre' done d m s0 s ->
        pre done d m s0 s) ->
      valid tid pre' p.
  Proof.
    unfold valid.
    intros.
    apply H0 in H1.
    eauto.
  Qed.

  Definition If_ P Q (b: {P} + {Q}) (ptrue pfalse : prog) :=
    if b then ptrue else pfalse.

  Fixpoint For_ (L : Type) (G : Type) (f : nat -> L -> (L -> prog) -> prog)
             (i n : nat)
             (nocrash : G -> nat -> L -> DISK -> M -> S -> S -> Prop)
             (l : L)
             (rx: L -> prog) : prog :=
    match n with
    | O => rx l
    | Datatypes.S n' =>  (f i l) (fun l' => For_ f (1 + i) n' nocrash l' rx)
    end.

  Lemma valid_exists_to_forall : forall A tid pre p,
      (forall a:A, valid tid (fun done d m s0 s =>
                           pre done d m s0 s a) p) ->
      (valid tid (fun done d m s0 s =>
                    exists a, pre done d m s0 s a) p).
  Proof.
    unfold valid; intros; deex; eauto.
  Qed.

  Ltac especialize H :=
    match type of H with
    | forall (a:?A), _ =>
      let a' := fresh a in
      evar (a':A);
        specialize (H a');
        subst a'
    end.

  Lemma pimpl_pre_valid : forall tid (pre: donecond -> _ -> _ -> _ -> _ -> Prop)
                            pre' p,
      (forall done d m s0 s, pre done d m s0 s ->
                              valid tid (pre' done) p) ->
      (forall done d m s0 s, pre done d m s0 s ->
                              pre' done done d m s0 s) ->
      valid tid pre p.
  Proof.
    unfold valid; eauto.
  Qed.

  Hint Extern 4 (_ <= _) => omega.
  Hint Extern 5 (@eq nat _ _) => omega.

  Theorem for_ok' : forall tid L G
                     (rx: _ -> prog)
                     nocrash
                     n i f (li:L),
      valid tid (fun done =>
                   fun d m s0 s =>
                     exists (g:G),
                       nocrash g i li d m s0 s /\
                       (forall n' ln' rxm,
                           i <= n' ->
                           n' < n + i ->
                           (forall lSm,
                               valid tid (fun done' d' m' s0' s' =>
                                            nocrash g (1+n') lSm d' m' s0' s' /\
                                            done' = done) (rxm lSm)) ->
                           valid tid (fun done' d' m' s0' s' =>
                                        nocrash g n' ln' d' m' s0' s' /\
                                        done' = done) (f n' ln' rxm)) /\
                       (forall lfinal,
                           valid tid (fun done' d' m' s0' s' =>
                                        nocrash g (i+n) lfinal d' m' s0' s' /\
                                        done' = done) (rx lfinal)))
            (For_ f i n nocrash li rx).
  Proof.
    intro.
    induction n; cbn; intros.
    - unfold valid in *; intros; repeat deex.
      (* TODO: ring_simplify should handle this *)
      rewrite <- plus_n_O in *.
      eauto.
    - apply valid_exists_to_forall; intros.
      eapply pimpl_pre_valid; intuition.
      eapply pimpl_ok.
      apply H; eauto.
      intros; eapply pimpl_ok.
      apply IHn.
      intuition; subst; cbn.
      match goal with
      | [ g: ?G |- exists _:?G, _ ] => exists g
      end; intuition eauto.
      eapply pimpl_ok; eauto.
      intuition eauto.
      (* TODO: ring_simplify should handle this *)
      match goal with
      | [ H: nocrash _ ?i ?l _ _ _ _
          |- nocrash _ ?i' ?l _ _ _ _ ] =>
        replace i with i' in H by omega; assumption
      end.

      (* TODO: proof has diverged here for some reason from previous
      version (when we had crashes) and original FSCQ BasicProg for
      loops *)
      intros.
      (* eapply H2. *)
      intuition.
  Admitted.

  Theorem for_ok : forall tid L G
                     (rx: _ -> prog)
                     nocrash
                     n f (li:L),
      valid tid (fun done =>
                   fun d m s0 s =>
                     exists (g:G),
                       nocrash g 0 li d m s0 s /\
                       (forall n' ln' rxm,
                           n' < n ->
                           (forall lSm,
                               valid tid (fun done' d' m' s0' s' =>
                                            nocrash g (1+n') lSm d' m' s0' s' /\
                                            done' = done) (rxm lSm)) ->
                           valid tid (fun done' d' m' s0' s' =>
                                        nocrash g n' ln' d' m' s0' s' /\
                                        done' = done) (f n' ln' rxm)) /\
                       (forall lfinal,
                           valid tid (fun done' d' m' s0' s' =>
                                        nocrash g n lfinal d' m' s0' s' /\
                                        done' = done) (rx lfinal)))
            (For_ f 0 n nocrash li rx).
  Proof.
    intros.
    apply valid_exists_to_forall; intros.
    eapply pimpl_ok.
    apply for_ok'.
    intros; intuition.
    match goal with
    | [ g: ?G |- exists _:?G, _ ] => exists g
    end; intuition eauto.
  Qed.

End EventCSL.

(** transitions defines a transition system, grouping the StateR and StateI
variables above.

This makes the notation more convenient, since R and I can be specified in one
ident.
*)
Record transitions Mcontents S := {
      (* StateR s s' holds when s -> s' is a valid transition *)
      StateR: ID -> Relation S;
      (* StateI m s d holds when the ghost state s matches the memory m and disk d,
        and any important invariants across them hold in all three *)
      StateI: Invariant Mcontents S;
      }.

(** Copy-paste metaprogramming:

* Copy the above notation
* add sigma, tid |- in front to specify the transition system and thread ID
* quantify over T and tid and change prog to prog _ _ T (the state/mem types should be inferred)
* add (StateR sigma) (StateI sigma) as arguments to valid *)
Notation "sigma 'TID' ':' tid |- {{ e1 .. e2 , | 'PRE' d m s0 s : pre | 'POST' d' m' s0' s' r : post }} p" :=
  (forall T (rx: _ -> prog _ _ T) (tid:ID),
      valid (StateR sigma) (StateI sigma) tid
            (fun done d m s0 s =>
               (ex (fun e1 => .. (ex (fun e2 =>
                                     pre%judgement /\
                                     (forall ret_,
                                       valid (StateR sigma) (StateI sigma) tid
                                             (fun done_rx d' m' s0' s' =>
                                                (fun r => post%judgement) ret_ /\
                                                done_rx = done)
                                             (rx ret_))
                              )) .. ))
            ) (p rx))
    (at level 0, p at level 60,
     e1 binder, e2 binder,
     d at level 0,
     d' at level 0,
     m at level 0,
     m' at level 0,
     s0 at level 0,
     s0' at level 0,
     s at level 0,
     s' at level 0,
     r at level 0,
     only parsing).

Notation "p1 ;; p2" := (progseq p1 (fun _:unit => p2))
                         (at level 60, right associativity).
Notation "x <- p1 ; p2" := (progseq p1 (fun x => p2))
                              (at level 60, right associativity).

(* maximally insert the return/state types for GetTID, which is always called
   without applying them to any arguments *)
Arguments GetTID {Mcontents} {Scontents} {T} rx.

Notation "'If' b { p1 } 'else' { p2 }" := (If_ b p1 p2) (at level 9, b at level 0).

(** This notation is intended to produce the patterns for prog hints.

The ; _ is merely a visual indicator that the pattern applies to any Hoare
statement beginning with f and followed by anything else. *)
Notation "{{ f ; '_' }}" := (valid _ _ _ _ (progseq f _)).

(* copy of pair_args_helper from Prog *)
Definition tuple_args (A B C:Type) (f: A->B->C) (x: A*B) := f (fst x) (snd x).

Notation "'For' i < n | 'Ghost' [ g1 .. g2 ] | 'Loopvar' [ l1 .. l2 ] | 'Continuation' lrx | 'LoopInv' nocrash | 'OnCrash' crashed | 'Begin' body | 'Rof'" :=
  (For_ (fun i =>
           (tuple_args
              (fun l1 => .. (tuple_args
                             (fun l2 (_:unit) => (fun lrx => body)))
                          ..)))
        0 n
        (tuple_args
           (fun g1 => .. (tuple_args
                          (fun g2 (_:unit) =>
                             fun i =>
                               (tuple_args
                                  (fun l1 => .. (tuple_args
                                                 (fun l2 (_:unit) => nocrash)) ..))
                       )) .. ))
        (tuple_args
           (fun g1 => .. (tuple_args
                          (fun g2 (_:unit) =>
                             crashed)) .. )))
    (at level 9, i at level 0, n at level 0,
     g1 closed binder, g2 closed binder,
     lrx at level 0,
     l1 closed binder, l2 closed binder,
     body at level 9).

Hint Extern 1 {{ StartRead _; _ }} => apply StartRead_ok : prog.
Hint Extern 1 {{ FinishRead _; _ }} => apply FinishRead_ok : prog.
Hint Extern 1 {{ Write _ _; _ }} => apply Write_ok : prog.
Hint Extern 1 {{ Get _; _ }} => apply Get_ok : prog.
Hint Extern 1 {{ Assgn _ _; _ }} => apply Assgn_ok : prog.
Hint Extern 1 {{ GetTID ; _ }} => apply GetTID_ok : prog.
Hint Extern 1 {{ Yield _; _ }} => apply Yield_ok : prog.
Hint Extern 1 {{ GhostUpdate _; _ }} => apply GhostUpdate_ok : prog.
Hint Extern 1 {{ Wakeup _; _ }} => apply Wakeup_ok : prog.
Hint Extern 1 {{ For_ _ _ _ _ _ _; _ }} => apply for_ok : prog.

(* Wrap up the parameters that the semantics takes in a module. *)
Module Type Semantics.
  Parameter Mcontents : list Type.
  Parameter Scontents : list Type.
  Parameter Inv : Invariant Mcontents Scontents.
  Parameter R : ID -> Relation Scontents.

  Axiom R_trans : forall tid s1 s2,
    star (R tid) s1 s2 -> R tid s1 s2.
End Semantics.
