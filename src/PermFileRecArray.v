Require Import Eqdep_dec Arith Omega List ListUtils Rounding Psatz.
Require Import Word WordAuto Pred.
Require Import Mem Rec.
Require Import ProofIrrelevance.
Require Import Errno.

Require Import PermGenSepN PermRecArrayUtils.
Require Export PermBFile MemMatch.

Import ListNotations EqNotations.

Set Implicit Arguments.


Module Type FileRASig.

  Parameter itemtype : Rec.type.
  Parameter items_per_val : nat.
  Parameter blocksz_ok : valulen = Rec.len (Rec.ArrayF itemtype items_per_val).

End FileRASig.

(** This is for read and write items packed inside the file blocks 
will defer until required. Will port with can access and unsealing **)

Module FileRecArray (FRA : FileRASig).

  (* Transform simplified file-based RecArray sig to general RASig *)
  Module RA <: RASig.

    Definition xparams := BFILE.bfile.
    Definition RAStart := fun (_ : xparams) => 0.
    Definition RALen := fun f => length (BFILE.BFData f).
    Definition xparams_ok := fun (_ : xparams) => True.

    Definition itemtype := FRA.itemtype.
    Definition items_per_val := FRA.items_per_val.
    Definition blocksz_ok := FRA.blocksz_ok.

    Definition RAData f := (BFILE.BFData f).
    Definition RAAttr f := (BFILE.BFAttr f).
  End RA.


  Module Defs := RADefs RA.
  Import RA Defs.

  Definition items_valid f (items : itemlist) :=
    length items = (RALen f) * items_per_val /\
    Forall Rec.well_formed items.


  (** rep invariant *)
  Definition rep f tags (items : itemlist) :=
    ( exists vl, [[ vl = ipack items ]] *
      [[ length tags = length vl ]] * 
      [[ items_valid f items ]] *
      arrayN (@ptsto _ addr_eq_dec _) 0 (synced_list (List.combine tags vl)))%pred.

  Definition get lxp ixp inum ix ms :=
    let '(bn, off) := (ix / items_per_val, ix mod items_per_val) in
    let^ (ms, sv) <- BFILE.read_array lxp ixp inum 0 bn ms;;
    v <- Unseal sv;;
    Ret ^(ms, selN_val2block v off).

  Definition put lxp ixp inum ix tag item ms :=
    let '(bn, off) := (ix / items_per_val, ix mod items_per_val) in
    let^ (ms, sv) <- BFILE.read_array lxp ixp inum 0 bn ms;;
    v <- Unseal sv;;      
    let v' := block2val_updN_val2block v off item in
    sv' <- Seal tag v';;
    ms <- BFILE.write_array lxp ixp inum 0 bn sv' ms;;
    Ret ms.
       
  (* extending one block and put item at the first entry *)
  Definition extend lxp bxp ixp inum tag item ms :=
    let v := block2val (updN block0 0 item) in
    sv <- Seal tag v;;
    let^ (ms, r) <- BFILE.grow lxp bxp ixp inum sv ms;;
    Ret ^(ms, r).

  Definition readall lxp ixp inum ms :=
    let^ (ms, nr) <- BFILE.getlen lxp ixp inum ms;;
    let^ (ms, rl) <- BFILE.read_range lxp ixp inum 0 nr ms;;
    r <- unseal_all rl;;
    Ret ^(ms, fold_left iunpack r nil).

  Definition init lxp bxp ixp inum ms :=
    let^ (ms, nr) <- BFILE.getlen lxp ixp inum ms;;
    ms <- BFILE.shrink lxp bxp ixp inum nr ms;;
    Ret ms.

  Notation MSLL := BFILE.MSLL.
  Notation MSAlloc := BFILE.MSAlloc.
  Notation MSAllocC := BFILE.MSAllocC.
  Notation MSICache := BFILE.MSICache.
  Notation MSCache := BFILE.MSCache.
  Notation MSIAllocC := BFILE.MSIAllocC.
  Notation MSDBlocks := BFILE.MSDBlocks.

  (* find the first item that satisfies cond *)
  Definition ifind lxp ixp inum (cond : item -> addr -> bool) ms0 :=
    let^ (ms, nr) <- BFILE.getlen lxp ixp inum ms0;;
    let^ (ms, ret) <- ForN i < nr
    Blockmem bm                                          
    Hashmap hm
    Ghost [ bxp F Fm Fi crash m0 sm m flist f tags items ilist frees ]
    Loopvar [ ms ret ]
    Invariant
      LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms) sm bm hm *
      [[[ m ::: (Fm * BFILE.rep bxp sm ixp flist ilist frees (MSAllocC ms) (MSCache ms) (MSICache ms) (MSDBlocks ms)) ]]] *
      [[[ flist ::: (Fi * inum |-> f) ]]] *
      [[[ RAData f ::: rep f tags items ]]] *
      [[ ret = None ->
         forall ix, ix < i * items_per_val ->
               cond (selN items ix item0) ix = false ]] *
      [[ forall st, ret = Some st ->
              cond (snd st) (fst st) = true
              /\ (fst st) < length items
              /\ snd st = selN items (fst st) item0 ]] *
      [[ MSAlloc ms = MSAlloc ms0 ]] *
      [[ MSCache ms = MSCache ms0 ]] *
      [[ MSIAllocC ms = MSIAllocC ms0 ]] *
      [[ MSAllocC ms = MSAllocC ms0 ]] *
      [[ MSDBlocks ms = MSDBlocks ms0 ]]
    OnCrash  crash
    Begin
        If (is_some ret) {
          Ret ^(ms, ret)
        } else {
            let^ (ms, sv) <- BFILE.read_array lxp ixp inum 0 i ms;;
            v <- Unseal sv;;
            let r := ifind_block cond (val2block v) (i * items_per_val) in
            match r with
            | None => Ret ^(ms, None)
            | Some ifs => Ret ^(ms, Some ifs)
            end
        }
    Rof ^(ms, None);;
    Ret ^(ms, ret).


  Local Hint Resolve items_per_val_not_0 items_per_val_gt_0 items_per_val_gt_0'.

  Lemma items_valid_updN : forall xp items a v,
    items_valid xp items ->
    Rec.well_formed v ->
    items_valid xp (updN items a v).
  Proof.
    unfold items_valid; intuition.
    rewrite length_updN; auto.
    apply Forall_wellformed_updN; auto.
  Qed.

  Lemma ifind_length_ok : forall xp i tags items,
    i < RALen xp ->
    items_valid xp items ->
    length tags = length (ipack items) ->
    i < length (synced_list (List.combine tags (ipack items))).
  Proof.
    unfold items_valid; intuition.
    rewrite synced_list_length.
    setoid_rewrite combine_length_eq; auto.
    rewrite H1, ipack_length; auto.
    setoid_rewrite H2; rewrite divup_mul; auto.
  Qed.

  Lemma items_valid_length_eq : forall xp a b,
    items_valid xp a ->
    items_valid xp b ->
    length (ipack a) = length (ipack b).
  Proof.
    unfold items_valid; intuition.
    eapply ipack_length_eq; eauto.
  Qed.

  Hint Extern 0 (okToUnify (BFILE.rep _ _ _ _ _ _ _ _ _ _) (BFILE.rep _ _ _ _ _ _ _ _ _ _)) => setoid_rewrite <- surjective_pairing : okToUnify.

  Theorem get_ok :
    forall lxp ixp bxp inum ix ms pr,
    {< F Fm Fi m0 sm m flist f tags items ilist frees,
    PERM:pr   
    PRE:bm, hm,
          LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms) sm bm hm *
          [[ ix < length items ]] *
          [[[ m ::: (Fm * BFILE.rep bxp sm ixp flist ilist frees (MSAllocC ms) (MSCache ms) (MSICache ms) (MSDBlocks ms)) ]]] *
          [[[ flist ::: (Fi * inum |-> f) ]]] *
          [[[ RAData f ::: rep f tags items ]]] *
          [[ can_access pr (selN tags (ix / items_per_val) Public) ]]
    POST:bm', hm', RET:^(ms', r)
          LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms') sm bm' hm' *
          [[ r = selN items ix item0 ]] *
          [[[ m ::: (Fm * BFILE.rep bxp sm ixp flist ilist frees (MSAllocC ms') (MSCache ms') (MSICache ms') (MSDBlocks ms')) ]]] *
          [[ MSAlloc ms' = MSAlloc ms ]] *
          [[ MSCache ms' = MSCache ms ]] *
          [[ MSIAllocC ms' = MSIAllocC ms ]] *
          [[ MSDBlocks ms' = MSDBlocks ms ]] *
          [[ MSAllocC ms' = MSAllocC ms]]
    CRASH:bm', hm',  exists ms',
           LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms') sm bm' hm'
    >} get lxp ixp inum ix ms.
  Proof. 
    unfold get, rep.
    prestep.
    intros m Hm;
    destruct_lift Hm.
    repeat eexists.
    pred_apply; norm.
    cancel.
    unfold RAData in *.
    intuition.
    pred_apply; cancel.
    eauto.
    eassign (emp(AT:=addr)(AEQ:=addr_eq_dec)(V:=valuset)); pred_apply; cancel.
    

    (* [rewrite selN_val2block_equiv] somewhere *)
    rewrite synced_list_length.
    setoid_rewrite combine_length_eq; auto.
    rewrite H18, ipack_length; eauto.
    apply div_lt_divup; auto.

    safestep.
    apply H6.
    denote (bm0 _ = _) as Hx.    
    setoid_rewrite synced_list_selN in Hx.
    setoid_rewrite selN_combine in Hx; eauto.

    step.
    safestep; msalloc_eq.
    erewrite LOG.rep_hashmap_subset; eauto.
    erewrite selN_val2block_equiv.
    apply ipack_selN_divmod; auto.
    apply list_chunk_wellformed; auto.
    unfold items_valid in *; intuition; auto.
    apply Nat.mod_upper_bound; auto.
    cancel.

    Unshelve.
    all: eauto.
  Qed.

  Theorem put_ok :
    forall lxp ixp bxp inum ix tag e ms pr,
    {< F Fm Fi m0 sm m flist f tags items ilist frees,
    PERM:pr                  
    PRE:bm, hm,
          LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms) sm bm hm *
          [[ ix < length items /\ Rec.well_formed e ]] *
          [[[ m ::: (Fm * BFILE.rep bxp sm ixp flist ilist frees (MSAllocC ms) (MSCache ms) (MSICache ms) (MSDBlocks ms)) ]]] *
          [[[ flist ::: (Fi * inum |-> f) ]]] *
          [[[ RAData f ::: rep f tags items ]]] *
          [[ can_access pr (selN tags (ix / items_per_val) Public) ]] *
          [[ can_access pr tag ]] *
          [[ tag = INODE.IOwner(selN ilist inum INODE.inode0) ]]
    POST:bm', hm', RET:ms' exists m' flist' f',
          LOG.rep lxp F (LOG.ActiveTxn m0 m') (MSLL ms') sm bm' hm' *
          [[[ m' ::: (Fm * BFILE.rep bxp sm ixp flist' ilist frees (MSAllocC ms') (MSCache ms') (MSICache ms') (MSDBlocks ms')) ]]] *
          [[[ flist' ::: (Fi * inum |-> f') ]]] *
          [[[ RAData f' ::: rep f' (updN tags (ix / items_per_val) tag) (updN items ix e) ]]] *
          [[ MSAlloc ms' = MSAlloc ms ]] *
          [[ MSCache ms' = MSCache ms ]] *
          [[ MSIAllocC ms' = MSIAllocC ms ]] *
          [[ MSAllocC ms' = MSAllocC ms ]] (* *
          [[ MSDBlocks ms' = MSDBlocks ms ]] *)
    CRASH:bm', hm', LOG.intact lxp F m0 sm bm' hm'
    >} put lxp ixp inum ix tag e ms.
  Proof. 
    unfold put, rep.
    prestep.
    intros m Hm;
    destruct_lift Hm.
    repeat eexists.
    pred_apply; norm.
    cancel.
    intuition.
    pred_apply; cancel.
    eauto.
    unfold RAData in *;
    eassign (emp(AT:=addr)(AEQ:=addr_eq_dec)(V:=valuset)); pred_apply; cancel.
    rewrite synced_list_length.
    setoid_rewrite combine_length_eq; auto.
    rewrite H21, ipack_length; eauto.
    apply div_lt_divup; auto.

    safestep.
    apply H8.
    denote (bm0 _ = _) as Hx.    
    setoid_rewrite synced_list_selN in Hx.
    setoid_rewrite selN_combine in Hx; eauto.

    step.
    prestep.
    intros m' Hm';
    destruct_lift Hm'.
    repeat eexists.
    pred_apply; norm.
    cancel.
    erewrite LOG.rep_hashmap_subset; eauto; cancel.
    erewrite LOG.rep_blockmem_subset; eauto; cancel.
    Opaque corr2.
    repeat split.
    pred_apply; cancel.
    eauto.
    unfold RAData in *;
    eassign (emp(AT:=addr)(AEQ:=addr_eq_dec)(V:=valuset)); pred_apply; cancel.
    rewrite synced_list_length.
    setoid_rewrite combine_length_eq; auto.
    rewrite H21, ipack_length; eauto.
    apply div_lt_divup; auto.
    eapply upd_eq; eauto.
    right; simpl; auto.
    auto.

    step.
    safestep.
    erewrite LOG.rep_hashmap_subset; eauto; cancel.
    cleanup.
    pred_apply; cancel.
    cleanup. cancel.
    eauto.
    unfold RAData in *. simpl in *. pred_apply.
    cancel.

    apply arrayN_unify.
    rewrite synced_list_updN; f_equal; simpl.
    rewrite block2val_updN_val2block_equiv.
    setoid_rewrite <- combine_updN.
    rewrite ipack_updN_divmod; auto.
    apply list_chunk_wellformed.
    unfold items_valid in *; intuition; auto.
    apply Nat.mod_upper_bound; auto.
    rewrite ipack_length in *; repeat rewrite length_updN in *; auto.
    
    apply items_valid_updN; auto.
    unfold items_valid, RALen in *; simpl; intuition.
    rewrite length_updN; auto.
    all: intros; rewrite <- H2; cancel; eauto.

    Unshelve.
    all: eauto.
  Qed.


  Lemma extend_ok_helper :
    forall f e tag tags items,
    items_valid f items ->
    length tags = length (ipack items) ->                        
    length (BFILE.BFData f) |-> ((tag, block2val (updN block0 0 e)), []) *
    arrayN (@ptsto _ addr_eq_dec _) 0 (synced_list (List.combine tags (ipack items))) =p=>
    arrayN (@ptsto _ addr_eq_dec _) 0 (synced_list (List.combine (tags++[tag]) (ipack (items ++ (updN block0 0 e))))).
  Proof.
    intros.
    unfold items_valid, RALen in *; intuition.
    erewrite ipack_app, combine_app, synced_list_app by eauto.    
    rewrite arrayN_app, Nat.add_0_l; cancel.
    setoid_rewrite ipack_one at 2; simpl.
    rewrite synced_list_length.
    setoid_rewrite combine_length_eq; eauto.
    rewrite H0, ipack_length; auto.
    substl (length items); rewrite divup_mul; auto.
    cancel.
    rewrite block0_repeat. rewrite length_updN, repeat_length; auto.
  Qed.

  Lemma extend_item_valid : forall f e tag items,
    Rec.well_formed e ->
    items_valid f items ->
    items_valid {| BFILE.BFData := BFILE.BFData f ++ [((tag, block2val (updN block0 0 e)), [])];
                   BFILE.BFAttr := BFILE.BFAttr f;
                   BFILE.BFCache := BFILE.BFCache f |}  (items ++ (updN block0 0 e)).
  Proof.
    unfold items_valid, RALen in *; intuition; simpl.
    repeat rewrite app_length; simpl.
    rewrite block0_repeat, length_updN, repeat_length.
    rewrite Nat.mul_add_distr_r, Nat.mul_1_l; omega.
    apply Forall_append; auto.
    apply Forall_updN; auto.
    rewrite block0_repeat.
    apply Forall_repeat.
    apply item0_wellformed.
  Qed.

  Theorem extend_ok :
    forall lxp ixp bxp inum tag e ms pr,
    {< F Fm Fi m0 sm m flist f tags items ilist frees,
    PERM:pr   
    PRE:bm, hm,
          LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms) sm bm hm *
          [[ Rec.well_formed e ]] *
          [[[ m ::: (Fm * BFILE.rep bxp sm ixp flist ilist frees (MSAllocC ms) (MSCache ms) (MSICache ms) (MSDBlocks ms)) ]]] *
          [[[ flist ::: (Fi * inum |-> f) ]]] *
          [[[ RAData f ::: rep f tags items ]]] *
          [[ can_access pr tag ]] *
          [[ tag = INODE.IOwner(selN ilist inum INODE.inode0) ]]
    POST:bm', hm', RET: ^(ms', r) exists m',
         [[ MSAlloc ms' = MSAlloc ms ]] *
         [[ MSCache ms' = MSCache ms ]] *
         [[ MSIAllocC ms' = MSIAllocC ms ]] *
         ([[ isError r ]] * 
          LOG.rep lxp F (LOG.ActiveTxn m0 m') (MSLL ms') sm bm' hm' \/
          [[ r = OK tt  ]] *
          exists flist' f' ilist' frees',
          LOG.rep lxp F (LOG.ActiveTxn m0 m') (MSLL ms') sm bm' hm' *
          [[[ m' ::: (Fm * BFILE.rep bxp sm ixp flist' ilist' frees' (MSAllocC ms') (MSCache ms') (MSICache ms') (MSDBlocks ms')) ]]] *
          [[[ flist' ::: (Fi * inum |-> f') ]]] *
          [[[ RAData f' ::: rep f' (tags++[tag]) (items ++ (updN block0 0 e)) ]]] *
          [[ BFILE.ilist_safe ilist  (BFILE.pick_balloc frees  (MSAlloc ms'))
                              ilist' (BFILE.pick_balloc frees' (MSAlloc ms')) ]] *
          [[ BFILE.treeseq_ilist_safe inum ilist ilist' ]] *
          listmatch (fun i1 i2 => [[INODE.IOwner i1 = INODE.IOwner i2]]) ilist ilist')
    CRASH:bm', hm', LOG.intact lxp F m0 sm bm' hm'
    >} extend lxp bxp ixp inum tag e ms.
  Proof. 
    unfold extend, rep.
    prestep. norm. cancel.
    intuition.
    prestep.
    intros mx Hmx.
    destruct_lift Hmx.
    repeat eexists.
    pred_apply; norm.
    cancel.
    erewrite LOG.rep_hashmap_subset; eauto; cancel.
    erewrite LOG.rep_blockmem_subset; eauto; cancel.
    repeat split.
    eauto. eauto. eauto.
    eapply upd_eq; eauto.
    right; simpl; auto.
    auto.

    step.
    safestep.
 
    or_l; safecancel.
    erewrite LOG.rep_hashmap_subset; eauto; cancel.

    safestep.
    or_r. norm; [ cancel | intuition eauto ].
    erewrite LOG.rep_hashmap_subset; eauto; cancel.

    rewrite BFILE.rep_length_pimpl in H19; destruct_lift H19.
    rewrite BFILE.rep_length_pimpl in H0; destruct_lift H0.
    unfold BFILE.ilist_safe, BFILE.treeseq_ilist_safe in *.
    apply list2nmem_ptsto_bound in H8.
    cleanup.
    rewrite listmatch_isolate with (i:= inum); try omega.    
    cancel; eauto.
    erewrite list_selN_ext' with (a:= (removeN ilist inum))(b:= (removeN ilist' inum)).
    unfold listmatch; cancel.
    apply listpred_emp_piff.
    intros.
    destruct x; simpl.
    split; cancel.
    denote In as Hy;
    eapply in_selN_exists in Hy; cleanup.
    rewrite selN_combine with (a0:=INODE.inode0)(b0:=INODE.inode0) in H32; cleanup.
    inversion H32; subst; auto.
    auto.
    eauto.
    repeat rewrite removeN_length; omega.
    intros.
    unfold removeN.
    destruct (lt_dec pos inum).
    repeat rewrite selN_app1; auto.
    repeat rewrite selN_firstn; auto.
    apply H15; omega.
    rewrite firstn_length_l; omega.
    rewrite firstn_length_l; omega.
    apply Nat.nlt_ge in n.
    repeat rewrite selN_app2; auto.
    repeat rewrite firstn_length_l; try omega.
    repeat rewrite skipn_selN.
    apply H15; omega.
    rewrite firstn_length_l; try omega.
    rewrite firstn_length_l; try omega.
    
    simpl; pred_apply; norm; [ | intuition ].
    cancel; apply extend_ok_helper; auto.
    rewrite ipack_length in *.
    setoid_rewrite app_length;
    rewrite block0_repeat. rewrite length_updN, repeat_length; auto.
    replace items_per_val with (items_per_val * 1) at 1 by omega.
    rewrite divup_add; cleanup; auto.
    apply extend_item_valid; auto.

    all: intros; rewrite <- H1; cancel; eauto.

    Unshelve.
    all: eauto.
    exact INODE.inode0.
  Qed.


  Theorem readall_ok :
    forall lxp ixp bxp inum ms pr,
    {< F Fm Fi m0 sm m flist f tags items ilist frees,
    PERM:pr   
    PRE:bm, hm,
          LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms) sm bm hm *
          [[[ m ::: (Fm * BFILE.rep bxp sm ixp flist ilist frees (MSAllocC ms) (MSCache ms) (MSICache ms) (MSDBlocks ms)) ]]] *
          [[[ flist ::: (Fi * inum |-> f) ]]] *
          [[[ RAData f ::: rep f tags items ]]] *
          [[ Forall (can_access pr) tags ]]
    POST:bm', hm', RET:^(ms', r)
          LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms') sm bm' hm' *
          [[ r = items ]] *
          [[[ m ::: (Fm * BFILE.rep bxp sm ixp flist ilist frees (MSAllocC ms') (MSCache ms') (MSICache ms') (MSDBlocks ms')) ]]] *
          [[ MSAlloc ms' = MSAlloc ms ]] *
          [[ MSCache ms' = MSCache ms ]] *
          [[ MSIAllocC ms' = MSIAllocC ms ]] *
          [[ MSAllocC ms' = MSAllocC ms ]] *
          [[ MSDBlocks ms' = MSDBlocks ms ]]
    CRASH:bm', hm',  exists ms',
           LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms') sm bm' hm'
    >} readall lxp ixp inum ms.
  Proof. 
    unfold readall, rep.
    prestep.
    intros m Hm.
    destruct_lift Hm.
    repeat eexists.
    pred_apply; norm.
    cancel.
    intuition.
    eauto. eauto.

    prestep.
    intros mx Hmx.
    destruct_lift Hmx.
    repeat eexists.
    pred_apply; norm.
    cancel.
    Opaque corr2.
    repeat split.
    eauto. eauto.
    unfold RAData in *.
    eassign (emp(AT:=addr)(AEQ:=addr_eq_dec)(V:=valuset)); pred_apply; cancel.
    setoid_rewrite arrayN_list_eq at 2; eauto.
    unfold RAData; apply list2nmem_array.
    auto.

    step.
    cleanup. rewrite H29 in H10.
    rewrite synced_list_map_fst, firstn_oob, map_fst_combine in H10; auto.
    rewrite Forall_forall in *; eauto.
    rewrite <- synced_list_length at 1.
    setoid_rewrite arrayN_list_eq at 2; eauto.
    unfold RAData; apply list2nmem_array.

    msalloc_eq.
    step.
    safestep.
    erewrite LOG.rep_hashmap_subset; eauto; cancel.
    erewrite LOG.rep_blockmem_subset; eauto; cancel.
    cleanup.
    subst; rewrite synced_list_map_fst, firstn_oob, map_snd_combine; auto.
    unfold items_valid, RALen in *; intuition.
    erewrite iunpack_ipack; eauto.
    rewrite <- synced_list_length at 1.
    setoid_rewrite arrayN_list_eq at 2; eauto.
    unfold RAData; apply list2nmem_array.
    intros; rewrite <- H2; cancel; eauto.

    Unshelve.
    all: eauto.
  Qed.


  Theorem init_ok :
    forall lxp bxp ixp inum ms pr,
    {< F Fm Fi m0 sm m flist f ilist frees,
    PERM:pr   
    PRE:bm, hm,
          LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms) sm bm hm *
          [[[ m ::: (Fm * BFILE.rep bxp sm ixp flist ilist frees (MSAllocC ms) (MSCache ms) (MSICache ms) (MSDBlocks ms)) ]]] *
          [[[ flist ::: (Fi * inum |-> f) ]]]
    POST:bm', hm', RET:ms' exists m' flist' f' ilist' frees',
          LOG.rep lxp F (LOG.ActiveTxn m0 m') (MSLL ms') sm bm' hm' *
          [[[ m' ::: (Fm * BFILE.rep bxp sm ixp flist' ilist' frees' (MSAllocC ms') (MSCache ms') (MSICache ms') (MSDBlocks ms')) ]]] *
          [[[ flist' ::: (Fi * inum |-> f') ]]] *
          [[[ RAData f' ::: emp ]]] *
          [[ MSAlloc ms' = MSAlloc ms ]] *
          [[ MSCache ms' = MSCache ms ]] *
          [[ MSIAllocC ms' = MSIAllocC ms ]] *
          [[ BFILE.ilist_safe ilist  (BFILE.pick_balloc frees  (MSAlloc ms'))
                              ilist' (BFILE.pick_balloc frees' (MSAlloc ms')) ]]
    CRASH:bm', hm', LOG.intact lxp F m0 sm bm' hm'
    >} init lxp bxp ixp inum ms.
  Proof. 
    unfold init, rep.
    prestep.
    intros m Hm.
    destruct_lift Hm.
    repeat eexists.
    pred_apply; norm.
    cancel.
    intuition.
    eauto. eauto.

    prestep.
    intros mx Hmx.
    destruct_lift Hmx.
    repeat eexists.
    pred_apply; norm.
    cancel.
    intuition.
    msalloc_eq.
    pred_apply. eauto.
    eauto.

    step.
    safestep.
    erewrite LOG.rep_hashmap_subset; eauto; cancel.
    msalloc_eq.
    pred_apply; cancel.
    eauto.
    unfold RAData; simpl.

    subst; rewrite Nat.sub_diag; simpl.
    unfold list2nmem; simpl.
    apply emp_empty_mem.
    auto.

    all: rewrite <- H2; cancel; eauto.

    Unshelve.
    all: eauto.
  Qed.


  Theorem ifind_ok :
    forall lxp bxp ixp inum cond ms pr,
    {< F Fm Fi m0 sm m flist f tags items ilist frees,
    PERM:pr   
    PRE:bm, hm,
          LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms) sm bm hm *
          [[[ m ::: (Fm * BFILE.rep bxp sm ixp flist ilist frees (MSAllocC ms) (MSCache ms) (MSICache ms) (MSDBlocks ms)) ]]] *
          [[[ flist ::: (Fi * inum |-> f) ]]] *
          [[[ RAData f ::: rep f tags items ]]] *
          [[ Forall (can_access pr) tags ]]
    POST:bm', hm', RET:^(ms', r)
          LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms') sm bm' hm' *
          [[[ m ::: (Fm * BFILE.rep bxp sm ixp flist ilist frees (MSAllocC ms') (MSCache ms') (MSICache ms') (MSDBlocks ms')) ]]] *
          [[ MSAlloc ms' = MSAlloc ms ]] *
          [[ MSCache ms' = MSCache ms ]] *
          [[ MSAllocC ms' = MSAllocC ms ]] *
          [[ MSIAllocC ms' = MSIAllocC ms ]] *
          [[ MSDBlocks ms' = MSDBlocks ms ]] *
        ( [[ r = None /\ forall i, i < length items ->
                         cond (selN items i item0) i = false  ]]
          \/ exists st,
          [[ r = Some st /\ cond (snd st) (fst st) = true
                         /\ (fst st) < length items
                         /\ snd st = selN items (fst st) item0 ]])
    CRASH:bm', hm',  exists ms',
           LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms') sm bm' hm'
    >} ifind lxp ixp inum cond ms.
  Proof. 
    unfold ifind, rep.
    prestep.
    intros m Hm.
    destruct_lift Hm.
    repeat eexists.
    pred_apply; norm.
    cancel.
    intuition.
    eauto.
    eauto.

    prestep.
    intros mx Hmx.
    destruct_lift Hmx.
    repeat eexists.
    pred_apply; norm.
    2: intuition.
    eassign dummy; cancel.
    instantiate (1:=((bxp_1, bxp_2), (dummy0, (dummy1,
                     (dummy2, (false_pred, (dummy3,
                     (dummy4, (dummy5, (dummy6, (dummy7,
                     (dummy8, (dummy9, (dummy10,
                     (dummy12_1, dummy12_2, tt))))))))))))))).
    all: simpl in *.
    eauto.
    msalloc_eq.
    pred_apply; cancel.
    eauto.
    pred_apply; cancel.
    inversion H9.
    congruence.
    congruence.
    congruence.
    
    safestep.
    step.
    safestep.
    erewrite LOG.rep_hashmap_subset; eauto; cancel.

    prestep.
    intros my Hmy.
    destruct_lift Hmy.
    repeat eexists.
    pred_apply; norm.
    cancel.
    intuition.
    eauto.
    eauto.
    unfold RAData in *.
    eassign (emp(AT:=addr)(AEQ:=addr_eq_dec)(V:=valuset)); pred_apply; cancel.
    eapply lt_le_trans; eauto.
    setoid_rewrite arrayN_list_eq at 2; eauto.
    unfold RAData; apply list2nmem_array.

    safestep.
    eassign (selN dummy8 m0 Public).
    eapply Forall_selN; eauto.
    unfold items_valid in *; intuition idtac.
    cleanup.
    rewrite ipack_length.
    setoid_rewrite H25; rewrite divup_mul; auto.
    
    denote (bm2 _ = _) as Hx.    
    setoid_rewrite synced_list_selN in Hx.
    setoid_rewrite selN_combine in Hx; eauto.

    safestep.
    safestep.
    erewrite LOG.rep_hashmap_subset; eauto; cancel.
    unfold items_valid, RALen in *; intuition.
    eapply ifind_result_inbound; eauto.
    eapply ifind_result_item_ok; eauto.
    unfold items_valid, RALen in *; intuition.
    unfold items_valid, RALen in *; intuition.

    all: try solve [unfold false_pred; rewrite <- H2; cancel; eauto].

    safestep.
    erewrite LOG.rep_hashmap_subset; eauto; cancel.
    eapply ifind_block_none_progress; eauto.
    setoid_rewrite synced_list_selN.
    setoid_rewrite selN_combine; eauto.
    unfold items_valid in *; intuition idtac.
    cleanup.
    unfold items_valid in *; intuition idtac.


    step.
    safestep.
    erewrite LOG.rep_hashmap_subset; eauto; cancel.
    msalloc_eq.
    destruct a1.
    match goal with
    | [ H: forall _, Some _ = Some _ -> _ |- _ ] =>
      edestruct H; eauto
    end.
    or_r; cancel.
    or_l; cancel.
    unfold items_valid, RALen in *; intuition.

    Unshelve.
    all: try exact tt; eauto.
  Qed.

  Hint Extern 1 ({{_|_}} Bind (get _ _ _ _ _) _) => apply get_ok : prog.
  Hint Extern 1 ({{_|_}} Bind (put _ _ _ _ _ _ _) _) => apply put_ok : prog.
  Hint Extern 1 ({{_|_}} Bind (extend _ _ _ _ _ _ _) _) => apply extend_ok : prog.
  Hint Extern 1 ({{_|_}} Bind (readall _ _ _ _) _) => apply readall_ok : prog.
  Hint Extern 1 ({{_|_}} Bind (init _ _ _ _ _) _) => apply init_ok : prog.
  Hint Extern 1 ({{_|_}} Bind (ifind _ _ _ _ _) _) => apply ifind_ok : prog.


  (** operations using array spec *)

  Definition get_array lxp ixp inum ix ms :=
    r <- get lxp ixp inum ix ms;;
    Ret r.

  Definition put_array lxp ixp inum ix tag item ms :=
    r <- put lxp ixp inum ix tag item ms;;
    Ret r.

  Definition extend_array lxp bxp ixp inum tag item ms :=
    r <- extend lxp bxp ixp inum tag item ms;;
    Ret r.

  Definition ifind_array lxp ixp inum cond ms :=
    r <- ifind lxp ixp inum cond ms;;
    Ret r.

  Theorem get_array_ok :
    forall lxp ixp bxp inum ix ms pr,
    {< F Fm Fi Fe Ft m0 sm m flist f tags items t e ilist frees,
    PERM:pr   
    PRE:bm, hm,
          LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms) sm bm hm *
          [[[ m ::: (Fm * BFILE.rep bxp sm ixp flist ilist frees (MSAllocC ms) (MSCache ms) (MSICache ms) (MSDBlocks ms)) ]]] *
          [[[ flist ::: (Fi * inum |-> f) ]]] *
          [[[ RAData f ::: rep f tags items ]]] *
          [[[ items ::: Fe * ix |-> e ]]] *
          [[[ tags ::: Ft * (ix/items_per_val) |-> t ]]] *
          [[ can_access pr t ]]
    POST:bm', hm', RET:^(ms', r)
          LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms') sm bm' hm' *
          [[ r = e ]] *
          [[[ m ::: (Fm * BFILE.rep bxp sm ixp flist ilist frees (MSAllocC ms') (MSCache ms') (MSICache ms') (MSDBlocks ms')) ]]] *
          [[ MSAlloc ms' = MSAlloc ms ]] *
          [[ MSCache ms' = MSCache ms ]] *
          [[ MSIAllocC ms' = MSIAllocC ms ]] *
          [[ MSAllocC ms' = MSAllocC ms]]
    CRASH:bm', hm',  exists ms',
           LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms') sm bm' hm'
    >} get_array lxp ixp inum ix ms.
  Proof. 
    unfold get_array.
    prestep.
    intros m Hm.
    destruct_lift Hm.
    repeat eexists.
    pred_apply; norm.
    cancel.
    Opaque corr2.
    repeat split.
    eapply list2nmem_ptsto_bound; eauto.
    eauto.
    eauto.
    eauto.
    erewrite <- list2nmem_sel; eauto.
    eauto.

    step.
    step.
    erewrite LOG.rep_hashmap_subset; eauto; cancel.
    subst; apply eq_sym.
    eapply list2nmem_sel; eauto.
    intros; rewrite <- H2; cancel; eauto.
  Qed.


  Theorem put_array_ok :
    forall lxp ixp bxp inum ix t e ms pr,
    {< F Fm Fi Fe Ft m0 sm m flist f tags items t0 e0 ilist frees,
    PERM:pr   
    PRE:bm, hm,
          LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms) sm bm hm *
          [[ Rec.well_formed e ]] *
          [[[ m ::: (Fm * BFILE.rep bxp sm ixp flist ilist frees (MSAllocC ms) (MSCache ms) (MSICache ms) (MSDBlocks ms)) ]]] *
          [[[ flist ::: (Fi * inum |-> f) ]]] *
          [[[ RAData f ::: rep f tags items ]]] *
          [[[ items ::: Fe * ix |-> e0 ]]] *
          [[[ tags ::: Ft * (ix/items_per_val) |-> t0 ]]] *
          [[ can_access pr t ]] *
          [[ can_access pr t0 ]] *
          [[ t = INODE.IOwner(selN ilist inum INODE.inode0) ]]
    POST:bm', hm', RET:ms' exists m' flist' f' tags' items',
          LOG.rep lxp F (LOG.ActiveTxn m0 m') (MSLL ms') sm bm' hm' *
          [[[ m' ::: (Fm * BFILE.rep bxp sm ixp flist' ilist frees (MSAllocC ms') (MSCache ms') (MSICache ms') (MSDBlocks ms')) ]]] *
          [[[ flist' ::: (Fi * inum |-> f') ]]] *
          [[[ RAData f' ::: rep f' tags' items' ]]] *
          [[[ items' ::: Fe * ix |-> e ]]] *
          [[[ tags' ::: Ft * (ix/items_per_val) |-> t ]]] *
          [[ items' = updN items ix e ]] *
          [[ tags' = updN tags (ix/items_per_val) t ]] *
          [[ MSAlloc ms' = MSAlloc ms ]] *
          [[ MSCache ms' = MSCache ms ]] *
          [[ MSIAllocC ms' = MSIAllocC ms ]] *
          [[ MSAllocC ms' = MSAllocC ms ]] (* *
          [[ MSDBlocks ms' = MSDBlocks ms ]] *)
    CRASH:bm', hm', LOG.intact lxp F m0 sm bm' hm'
    >} put_array lxp ixp inum ix t e ms.
  Proof. 
    unfold put_array.
    prestep.
    intros m Hm.
    destruct_lift Hm.
    repeat eexists.
    pred_apply; norm.
    cancel.
    Opaque corr2.
    repeat split.
    eapply list2nmem_ptsto_bound; eauto.
    eauto.
    eauto.
    eauto.
    eauto.
    erewrite <- list2nmem_sel; eauto.
    eauto.
    eauto.

    step.
    step.
    erewrite LOG.rep_hashmap_subset; eauto; cancel.
    eapply list2nmem_updN; eauto.
    eapply list2nmem_updN; eauto.
    intros; rewrite <- H2; cancel; eauto.
  Qed.

  
  Theorem extend_array_ok :
    forall lxp bxp ixp inum t e ms pr,
    {< F Fm Fi Fe Ft m0 sm m flist f tags items ilist frees,
    PERM:pr   
    PRE:bm, hm,
          LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms) sm bm hm *
          [[ Rec.well_formed e ]] *
          [[[ m ::: (Fm * BFILE.rep bxp sm ixp flist ilist frees (MSAllocC ms) (MSCache ms) (MSICache ms) (MSDBlocks ms)) ]]] *
          [[[ flist ::: (Fi * inum |-> f) ]]] *
          [[[ RAData f ::: rep f tags items ]]] *
          [[[ items ::: Fe ]]] *
          [[[ tags ::: Ft ]]] *
          [[ can_access pr t ]] *
          [[ t = INODE.IOwner(selN ilist inum INODE.inode0) ]]
    POST:bm', hm', RET:^(ms', r) exists m',
         [[ MSAlloc ms' = MSAlloc ms ]] *
         [[ MSCache ms' = MSCache ms ]] *
         [[ MSIAllocC ms' = MSIAllocC ms ]] *
         ([[ isError r ]] * 
          LOG.rep lxp F (LOG.ActiveTxn m0 m') (MSLL ms') sm bm' hm' \/
          [[ r = OK tt ]] *
          exists flist' f' tags' items' ilist' frees',
          LOG.rep lxp F (LOG.ActiveTxn m0 m') (MSLL ms') sm bm' hm' *
          [[[ m' ::: (Fm * BFILE.rep bxp sm ixp flist' ilist' frees' (MSAllocC ms') (MSCache ms') (MSICache ms') (MSDBlocks ms')) ]]] *
          [[[ flist' ::: (Fi * inum |-> f') ]]] *
          [[[ RAData f' ::: rep f' tags' items' ]]] *
          [[[ items' ::: Fe * (length items) |-> e *
              arrayN (@ptsto _ addr_eq_dec _) (length items + 1)
                     (repeat item0 (items_per_val - 1)) ]]] *
          [[[ tags' ::: Ft * (length tags) |-> t ]]] *
          [[ items' = items ++ (updN block0 0 e)  ]] *
          [[ tags' = tags ++ [t]  ]] *
          [[ BFILE.ilist_safe ilist  (BFILE.pick_balloc frees  (MSAlloc ms'))
                              ilist' (BFILE.pick_balloc frees' (MSAlloc ms')) ]] *
          [[ BFILE.treeseq_ilist_safe inum ilist ilist' ]] )
    CRASH:bm', hm', LOG.intact lxp F m0 sm bm' hm'
    >} extend_array lxp bxp ixp inum t e ms.
  Proof. 
    unfold extend_array.
    prestep.
    intros m Hm.
    destruct_lift Hm.
    repeat eexists.
    pred_apply; norm.
    cancel.
    Opaque corr2.
    repeat split.
    eauto.
    eauto.
    eauto.
    eauto.
    eauto.
    eauto.

    step.
    step.
    erewrite LOG.rep_hashmap_subset; eauto; or_l; cancel.

    step.
    
    erewrite LOG.rep_hashmap_subset; eauto; or_r; cancel.

    rewrite block0_repeat.
    fold Rec.data.
    replace (updN (repeat item0 items_per_val) 0 e) with
            ([e] ++ (repeat item0 (items_per_val - 1))).
    replace (length dummy11 + 1) with (length (dummy11 ++ [e])).
    rewrite app_assoc.
    apply list2nmem_arrayN_app.
    apply list2nmem_app; auto.
    rewrite app_length; simpl; auto.
    rewrite updN_0_skip_1 by (rewrite repeat_length; auto).
    rewrite skipn_repeat; auto.
    apply list2nmem_app; auto.

    intros; rewrite <-H2; cancel; eauto.
  Qed.


  Theorem ifind_array_ok :
    forall lxp bxp ixp inum cond ms pr,
    {< F Fm Fi m0 sm m flist f tags items ilist frees,
    PERM:pr   
    PRE:bm, hm,
          LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms) sm bm hm *
          [[[ m ::: (Fm * BFILE.rep bxp sm ixp flist ilist frees (MSAllocC ms) (MSCache ms) (MSICache ms) (MSDBlocks ms)) ]]] *
          [[[ flist ::: (Fi * inum |-> f) ]]] *
          [[[ RAData f ::: rep f tags items ]]] *
          [[ Forall (can_access pr) tags ]]
    POST:bm', hm', RET:^(ms', r)
          LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms') sm bm' hm' *
          [[[ m ::: (Fm * BFILE.rep bxp sm ixp flist ilist frees (MSAllocC ms') (MSCache ms') (MSICache ms') (MSDBlocks ms')) ]]] *
          [[ MSAlloc ms' = MSAlloc ms ]] *
          [[ MSCache ms' = MSCache ms ]] *
          [[ MSAllocC ms' = MSAllocC ms ]] *
          [[ MSIAllocC ms' = MSIAllocC ms ]] *
          [[ MSDBlocks ms' = MSDBlocks ms ]] *
        ( [[ r = None    /\ forall i, i < length items ->
                            cond (selN items i item0) i = false ]] \/
          exists st,
          [[ r = Some st /\ cond (snd st) (fst st) = true ]] *
          [[[ items ::: arrayN_ex (@ptsto _ addr_eq_dec _) items (fst st) * (fst st) |-> (snd st) ]]] )
    CRASH:bm', hm',  exists ms',
           LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms') sm bm' hm'
    >} ifind_array lxp ixp inum cond ms.
  Proof.
    unfold ifind_array; intros.
    repeat monad_simpl_one.
    eapply pimpl_ok2. eauto with prog.
    intros.
    intros m Hm.
    destruct_lift Hm.
    repeat eexists.
    pred_apply; cancel.
    step.
    repeat monad_simpl_one.
    eapply pimpl_ok2. eauto with prog.
    safecancel.
    erewrite LOG.rep_hashmap_subset; eauto; cancel.
    or_l; cancel.

    step.
    erewrite LOG.rep_hashmap_subset; eauto; cancel.
    or_r; cancel.
    apply list2nmem_ptsto_cancel; auto.
  Qed.


  Hint Extern 1 ({{_|_}} Bind (get_array _ _ _ _ _) _) => apply get_array_ok : prog.
  Hint Extern 1 ({{_|_}} Bind (put_array _ _ _ _ _ _ _) _) => apply put_array_ok : prog.
  Hint Extern 1 ({{_|_}} Bind (extend_array _ _ _ _ _ _ _) _) => apply extend_array_ok : prog.
  Hint Extern 1 ({{_|_}} Bind (ifind_array _ _ _ _ _) _) => apply ifind_array_ok : prog.

  Hint Extern 0 (okToUnify (rep ?xp _ _) (rep ?xp _ _)) => constructor : okToUnify.


  Lemma items_wellformed : forall F xp tl l m,
    (F * rep xp tl l)%pred m -> Forall Rec.well_formed l.
  Proof.
    unfold rep, items_valid; intuition.
    destruct_lift H; auto.
  Qed.

  Lemma items_wellformed_pimpl : forall xp tl l,
    rep xp tl l =p=> [[ Forall Rec.well_formed l ]] * rep xp tl l.
  Proof.
    unfold rep, items_valid; cancel.
  Qed.

  Lemma item_wellformed : forall F xp m tl l i,
    (F * rep xp tl l)%pred m -> Rec.well_formed (selN l i item0).
  Proof.
    intros.
    destruct (lt_dec i (length l)).
    apply Forall_selN; auto.
    eapply items_wellformed; eauto.
    rewrite selN_oob by omega.
    apply item0_wellformed.
  Qed.

  Lemma items_length_ok : forall F xp tl l m,
    (F * rep xp tl l)%pred m ->
    length l = (RALen xp) * items_per_val.
  Proof.
    unfold rep, items_valid; intuition.
    destruct_lift H; auto.
  Qed.

  Lemma items_length_ok_pimpl : forall xp tl l,
    rep xp tl l =p=> [[ length l = ((RALen xp) * items_per_val)%nat ]] * rep xp tl l.
  Proof.
    unfold rep, items_valid; cancel.
  Qed.


  (* equality of items given the rep invariant *)

  Definition unpack blocks := fold_left iunpack blocks nil.

  Definition pack_unpack_cond (items : list item) :=
    Forall Rec.well_formed items /\ exists nr, length items = nr * items_per_val.

  Lemma pack_unpack_id : forall items,
    pack_unpack_cond items ->
    unpack (ipack items) = items.
  Proof.
    unfold pack_unpack_cond; intuition.
    destruct H1.
    eapply iunpack_ipack; eauto.
  Qed.

  Lemma ipack_injective :
    cond_injective (ipack) (pack_unpack_cond).
  Proof.
    eapply cond_left_inv_inj with (f' := unpack) (PB := fun _ => True).
    unfold cond_left_inverse; intuition.
    apply pack_unpack_id; auto.
  Qed.

  Lemma synced_list_injective :
    cond_injective (synced_list) (fun _ => True).
  Proof.
    eapply cond_left_inv_inj with (f' := map fst) (PB := fun _ => True).
    unfold cond_left_inverse; intuition.
    apply synced_list_map_fst; auto.
  Qed.

  Lemma rep_items_eq : forall m f tl1 tl2 vs1 vs2,
    rep f tl1 vs1 m ->
    rep f tl2 vs2 m ->
    tl1 = tl2 /\ vs1 = vs2.
  Proof.
    unfold rep, items_valid; intros.
    destruct_lift H; destruct_lift H0; subst.
    eapply arrayN_list_eq in H; eauto.
    apply synced_list_injective in H; auto.
    eapply combine_eq in H; eauto.
    intuition.
    apply ipack_injective; unfold pack_unpack_cond; eauto.
    cleanup.
    repeat rewrite ipack_length.
    setoid_rewrite H2.
    setoid_rewrite H3; auto.
    repeat rewrite ipack_length.
    setoid_rewrite H2.
    setoid_rewrite H3; auto.
  Qed.

  Lemma xform_rep : forall f tl vs,
    crash_xform (rep f tl vs) =p=> rep f tl vs.
  Proof.
    unfold rep; intros.
    xform_norm.
    rewrite crash_xform_arrayN_synced.
    cancel.
  Qed.

  Lemma file_crash_rep : forall f f' tl vs,
    BFILE.file_crash f f' ->
    rep f tl vs (list2nmem (BFILE.BFData f)) ->
    rep f' tl vs (list2nmem (BFILE.BFData f')).
  Proof.
    unfold rep; intros.
    destruct_lift H0; subst.
    eapply BFILE.file_crash_synced in H.
    intuition. rewrite <- H1.
    pred_apply; cancel.
    unfold items_valid, RALen in *; intuition congruence.
    eapply BFILE.arrayN_synced_list_fsynced; eauto.
  Qed.

  Lemma file_crash_rep_eq : forall f f' tl1 tl2 vs1 vs2,
    BFILE.file_crash f f' ->
    rep f  tl1 vs1 (list2nmem (BFILE.BFData f)) ->
    rep f' tl2 vs2 (list2nmem (BFILE.BFData f')) ->
    tl1 = tl2 /\ vs1 = vs2.
  Proof.
    intros.
    eapply rep_items_eq in H1.
    2: eapply file_crash_rep; eauto.
    eauto.
  Qed.


End FileRecArray.

