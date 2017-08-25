Require Import Prog.
Require Import Log.
Require Import BFile.
Require Import Word.
Require Import Omega.
Require Import Hashmap.   (* must go before basicprog, because notation using hashmap *)
Require Import BasicProg.
Require Import Bool.
Require Import Pred PredCrash.
Require Import DirName.
Require Import Hoare.
Require Import GenSepN.
Require Import ListPred.
Require Import SepAuto.
Require Import Idempotent.
Require Import Inode.
Require Import List ListUtils.
Require Import Balloc.
Require Import Bytes.
Require Import DirTree.
Require Import Rec.
Require Import Arith.
Require Import Array.
Require Import FSLayout.
Require Import Cache.
Require Import Errno.
Require Import AsyncDisk.
Require Import GroupLog.
Require Import SuperBlock.
Require Import DiskSet.
Require Import AsyncFS.
Require Import String.
Require Import DirTreeDef.
Require Import DirTreeRep.
Require Import DirTreeNames.
Require Import DirTreeSafe.
Require Import TreeCrash.
Require Import TreeSeq.
Require Import DirSep.
Require Import DirSepCrash.
Require Import SyncedMem.
Require Import AtomicCp.
Require Import BFileCrash.

Import TREESEQ.
Import DTCrash.
Import ListNotations.
Import ATOMICCP.

Set Implicit Arguments.

Lemma file_crash_trans: forall f1 f2 f3,
  file_crash f1 f2 ->
  file_crash f2 f3 ->
  file_crash f1 f3.
Proof.
  unfold file_crash; intros.
  repeat deex.
  do 2 eexists.
  eapply file_crash_trans; eauto.
Qed.

Lemma possible_fmem_crash_trans: forall m1 m2 m3,
  possible_fmem_crash m1 m2 ->
  possible_fmem_crash m2 m3 ->
  possible_fmem_crash m1 m3.
Proof.
  unfold possible_fmem_crash; intros.
  specialize (H a).
  specialize (H0 a).
  intuition;
  try solve [repeat deex; congruence].
  repeat deex.
  rewrite H0 in H1; inversion H1; subst; clear H1.
  right; do 2 eexists; repeat split; eauto.
  eapply BFileCrash.file_crash_trans; eauto.
Qed.
      

Lemma flist_crash_xform_idem: forall F,
  flist_crash_xform (flist_crash_xform F) =p=> flist_crash_xform F.
Proof.
  unfold flist_crash_xform; unfold pimpl; simpl; intros.
  repeat deex; intuition.
  exists mf'0; split; auto.
  eapply possible_fmem_crash_trans; eauto.
Qed.
    
Lemma treeseq_in_ds_crash_idem: forall ds ts Fm Ftop fsxp sm mscs ,
  treeseq_in_ds (crash_xform (crash_xform Fm))
      (flist_crash_xform (flist_crash_xform Ftop)) fsxp sm mscs ts ds
  -> treeseq_in_ds (crash_xform Fm) (flist_crash_xform Ftop) fsxp sm mscs ts ds.
Proof.  
  intros ds ts.
  destruct ds, ts.
  generalize dependent l0.
  induction l; simpl.
  intro l1; destruct l1.
  
  {
    unfold treeseq_in_ds, latest, NEforall2, TREESEQ.tree_rep, tree_rep_latest, rep; simpl; intros.
    intuition.
    destruct_lift H0.
    rewrite crash_xform_idem in H.
    destruct_lift H.
    rewrite flist_crash_xform_idem in H4.
    do 2 eexists; eauto.
    pred_apply; cancel.

    rewrite crash_xform_idem in H1.
    destruct_lift H1.
    rewrite flist_crash_xform_idem in H4.
    pred_apply; cancel.
  }
  
  {
    unfold treeseq_in_ds, latest, NEforall2; simpl; intros; intuition; inversion H2.
  }
  
  {
    intro l0; destruct l0.
    {
       unfold treeseq_in_ds, latest, NEforall2; simpl; intros; intuition; inversion H2.
    }
    
    unfold treeseq_in_ds, latest; simpl; intros.
    split.
    split; simpl.
    - destruct H.
      destruct H; simpl in *.
      intuition.
      
      unfold TREESEQ.tree_rep, tree_rep_latest, rep in *; simpl in *.
      destruct_lift H2.
      rewrite crash_xform_idem in H.
      rewrite flist_crash_xform_idem in H4.
      pred_apply; cancel.
    - destruct H.
      destruct H; simpl in *.
      induction H1.
      auto.
      apply Forall2_cons; auto.
      intuition.
      unfold TREESEQ.tree_rep, tree_rep_latest, rep in *; simpl in *.
      destruct_lift H.
      rewrite crash_xform_idem in H.
      rewrite flist_crash_xform_idem in H6.
      pred_apply; cancel.
    
    - destruct H.
      unfold tree_rep_latest, rep in *; simpl in *.
      rewrite crash_xform_idem in H0.
      destruct_lift H0.
      rewrite flist_crash_xform_idem in H2.
      pred_apply; cancel.
  }
Qed.


Lemma flatmem_entry_crash_trans: forall f1 f2 f3,
  flatmem_entry_crash f1 f2 ->  
  flatmem_entry_crash f2 f3 ->
  flatmem_entry_crash f1 f3.
Proof.
  induction 1; auto; intros.
  destruct f3; try constructor; try solve [
  inversion H0; subst;
  inversion H].
  inversion H0; subst.
  constructor.
  eapply file_crash_trans; eauto.
Qed.

Lemma possible_flatmem_crash_trans: forall m1 m2 m3,
  possible_flatmem_crash m1 m2 ->
  possible_flatmem_crash m2 m3 ->
  possible_flatmem_crash m1 m3.
Proof.
  unfold possible_flatmem_crash; intros.
  specialize (H a).
  specialize (H0 a).
  intuition;
  try solve [repeat deex; congruence].
  repeat deex.
  rewrite H0 in H1; inversion H1; subst; clear H1.
  right; do 2 eexists; repeat split; eauto.
  eapply flatmem_entry_crash_trans; eauto.
Qed.


Lemma flatmem_crash_xform_idem: forall F,
  flatmem_crash_xform (flatmem_crash_xform F) =p=> flatmem_crash_xform F.
Proof.
  unfold flatmem_crash_xform; unfold pimpl; intuition.
  repeat deex.
  eexists; split; eauto.
  eapply possible_flatmem_crash_trans; eauto.
Qed.

Lemma treeseq_pred_tree_rep_recover_idem: forall ts Ftree srcpath temp_fn srcinum file
  dstbase dstname dstfile,
  treeseq_pred (tree_rep_recover ( flatmem_crash_xform (flatmem_crash_xform Ftree)) srcpath [temp_fn] srcinum file dstbase dstname dstfile) ts ->
  treeseq_pred (tree_rep_recover (flatmem_crash_xform Ftree) srcpath [temp_fn] srcinum file dstbase dstname dstfile) ts.
Proof.
  intros; destruct ts, l; simpl in *.
  
  -
  unfold treeseq_pred, NEforall, tree_rep_recover in *; simpl in *.
  intuition.
  unfold tree_with_src in *.
  destruct_lift H2.
  rewrite flatmem_crash_xform_idem in H2.
  left; pred_apply; cancel.
  apply Forall_nil.
  unfold tree_with_dst in *.
  destruct_lift H2.
  rewrite flatmem_crash_xform_idem in H2.
  right; pred_apply; cancel.
  apply Forall_nil.
  
  -
   unfold treeseq_pred, tree_rep_recover in *; simpl in *.
   inversion H; subst; simpl in *; clear H.
   intuition.
   split; simpl.
   repeat (split; auto).
   unfold tree_with_src in *.
   destruct_lift H2.
   rewrite flatmem_crash_xform_idem in H2.
   left; pred_apply; cancel.
   induction H1.
   apply Forall_nil.
   apply Forall_cons; auto.
   intuition.
   unfold tree_with_src in *.
   destruct_lift H5.
   rewrite flatmem_crash_xform_idem in H5.
   left; pred_apply; cancel.
   unfold tree_with_dst in *.
   destruct_lift H5.
   rewrite flatmem_crash_xform_idem in H5.
   right; pred_apply; cancel.
   
   split; simpl.
   repeat (split; auto).
   unfold tree_with_dst in *.
   destruct_lift H2.
   rewrite flatmem_crash_xform_idem in H2.
   right; pred_apply; cancel.
   induction H1.
   apply Forall_nil.
   apply Forall_cons; auto.
   intuition.
   unfold tree_with_src in *.
   destruct_lift H5.
   rewrite flatmem_crash_xform_idem in H5.
   left; pred_apply; cancel.
   unfold tree_with_dst in *.
   destruct_lift H5.
   rewrite flatmem_crash_xform_idem in H5.
   right; pred_apply; cancel.
Qed.

Lemma treeseq_pred_tree_rep_idem: forall ts Ftree srcpath temp_fn srcinum file
  dstbase dstname dstfile dinum,
  treeseq_pred (tree_rep (flatmem_crash_xform (flatmem_crash_xform Ftree)) srcpath [temp_fn] srcinum file dinum dstbase dstname dstfile) ts ->
  treeseq_pred (tree_rep (flatmem_crash_xform Ftree) srcpath [temp_fn] srcinum file dinum dstbase dstname dstfile) ts.
Proof.
  intros; destruct ts, l; simpl in *.
  
  -
  unfold treeseq_pred, NEforall, tree_rep in *; simpl in *.
  intuition.
  unfold tree_with_tmp in *.
  deex.
  destruct_lift H2.
  rewrite flatmem_crash_xform_idem in H2.
  left; pred_apply; cancel.
  apply Forall_nil.
  unfold tree_with_src in *.
  destruct_lift H3.
  rewrite flatmem_crash_xform_idem in H2.
  right; left; pred_apply; cancel.
  apply Forall_nil.
  unfold tree_with_dst in *.
  destruct_lift H3.
  rewrite flatmem_crash_xform_idem in H2.
  right; right; pred_apply; cancel.
  apply Forall_nil.
  
  -
   unfold treeseq_pred, tree_rep in *; simpl in *.
   inversion H; subst; simpl in *; clear H.
   intuition.
   split; simpl.
   repeat (split; auto).
   unfold tree_with_tmp in *.
   deex; destruct_lift H2.
   rewrite flatmem_crash_xform_idem in H2.
   left; pred_apply; cancel.
   induction H1.
   apply Forall_nil.
   apply Forall_cons; auto.
   intuition.
   unfold tree_with_tmp in *.
  deex.
  destruct_lift H5.
  rewrite flatmem_crash_xform_idem in H5.
  left; pred_apply; cancel.
  unfold tree_with_src in *.
  destruct_lift H6.
  rewrite flatmem_crash_xform_idem in H5.
  right; left; pred_apply; cancel.
  unfold tree_with_dst in *.
  destruct_lift H6.
  rewrite flatmem_crash_xform_idem in H5.
  right; right; pred_apply; cancel.
   
   split; simpl.
   repeat (split; auto).
   unfold tree_with_src in *.
   destruct_lift H3.
   rewrite flatmem_crash_xform_idem in H2.
   right; left; pred_apply; cancel.
   induction H1.
   apply Forall_nil.
   apply Forall_cons; auto.
   intuition.
   unfold tree_with_tmp in *.
  deex.
  destruct_lift H5.
  rewrite flatmem_crash_xform_idem in H5.
  left; pred_apply; cancel.
  unfold tree_with_src in *.
  destruct_lift H6.
  rewrite flatmem_crash_xform_idem in H5.
  right; left; pred_apply; cancel.
  unfold tree_with_dst in *.
  destruct_lift H6.
  rewrite flatmem_crash_xform_idem in H5.
  right; right; pred_apply; cancel.
   
   split; simpl.
   repeat (split; auto).
   unfold tree_with_dst in *.
   destruct_lift H3.
   rewrite flatmem_crash_xform_idem in H2.
   right; right; pred_apply; cancel.
   induction H1.
   apply Forall_nil.
   apply Forall_cons; auto.
   intuition.
   unfold tree_with_tmp in *.
  deex.
  destruct_lift H5.
  rewrite flatmem_crash_xform_idem in H5.
  left; pred_apply; cancel.
  unfold tree_with_src in *.
  destruct_lift H6.
  rewrite flatmem_crash_xform_idem in H5.
  right; left; pred_apply; cancel.
  unfold tree_with_dst in *.
  destruct_lift H6.
  rewrite flatmem_crash_xform_idem in H5.
  right; right; pred_apply; cancel.
Qed.



Theorem copydata_with_recover_ok : forall fsxp srcinum tinum mscs,
    {X<< ds sm ts Fm Ftop Ftree srcpath file tfile v0 t0 dstbase dstname dstfile,
    PRE:hm
     LOG.rep (FSXPLog fsxp) (SB.rep fsxp) (LOG.NoTxn ds) (MSLL mscs) sm hm *
      [[ treeseq_in_ds Fm Ftop fsxp sm mscs ts ds ]] *
      [[ treeseq_pred (treeseq_safe [temp_fn] (MSAlloc mscs) (ts !!)) ts ]] *
      [[ treeseq_pred (tree_rep Ftree srcpath [temp_fn] srcinum file tinum dstbase dstname dstfile) ts ]] *
      [[ tree_with_tmp Ftree srcpath [temp_fn] srcinum file tinum
                tfile dstbase dstname dstfile (dir2flatmem2 (TStree ts!!)) ]] *
      [[[ DFData file ::: (Off0 |-> v0) ]]] *
      [[[ DFData tfile ::: (Off0 |-> t0) ]]]
(*       [[ dirtree_inum (TStree ts!!) = the_dnum ]] *)
    POST:hm' RET:^(mscs', r)
      exists ds' sm' ts',
       LOG.rep (FSXPLog fsxp) (SB.rep fsxp) (LOG.NoTxn ds') (MSLL mscs') sm' hm' *
       [[ MSAlloc mscs = MSAlloc mscs' ]] *
       [[ treeseq_in_ds Fm Ftop fsxp sm' mscs' ts' ds' ]] *
       [[ treeseq_pred (tree_rep Ftree srcpath [temp_fn] srcinum file tinum dstbase dstname dstfile) ts' ]] *
       (([[ isError r ]] *
          exists f', [[ tree_with_tmp Ftree srcpath [temp_fn] srcinum file tinum 
                f' dstbase dstname dstfile (dir2flatmem2 (TStree ts'!!)) ]])
         \/ ([[ r = OK tt ]] *
             [[ tree_with_tmp Ftree srcpath [temp_fn] srcinum file tinum 
                  (synced_dirfile file) dstbase dstname dstfile (dir2flatmem2 (TStree ts'!!)) ]]))
    REC:hm' RET:r
      [[ isError r ]] * any \/
      exists d sm' t mscs' dstfile',
      [[ r = OK (mscs', fsxp) ]] *
      LOG.rep (FSXPLog fsxp) (SB.rep fsxp) (LOG.NoTxn (d, nil)) (MSLL mscs') sm' hm' *
      [[ treeseq_in_ds (crash_xform Fm) (BFileCrash.flist_crash_xform Ftop) fsxp sm' mscs' (t, nil) (d, nil) ]] *
      [[ treeseq_pred (tree_rep_recover (flatmem_crash_xform Ftree) srcpath [temp_fn] srcinum file dstbase dstname dstfile') (t, nil) ]]
    >>X} copydata fsxp srcinum tinum mscs >> atomic_cp_recover.
  Proof.
    unfold forall_helper; intros.
    eapply pimpl_ok3; intros.
    eapply corr3_from_corr2_rx.
    apply copydata_ok.
    apply atomic_cp_recover_ok.
    
    cancel; eauto.
    specialize (H2 (a, (a0, b0))); simpl in H2; auto.
    eapply pimpl_ok2; eauto.
    simpl; cancel; eauto.
    or_l; cancel; eauto.
    or_r; cancel; eauto.
    instantiate (1:= fun hm' => (exists c, F_ * c * 
      [[ crash_xform (F_ * c) =p=> 
        F_ * crash_xform (
        (exists ds' sm' ts' mscs',
        LOG.idempred (FSXPLog fsxp) (SB.rep fsxp) ds' hm' *
        [[ treeseq_in_ds v2 v3 fsxp sm' mscs' ts' ds' ]] *
        [[ treeseq_pred (tree_rep v4 v5 [temp_fn] srcinum v6 tinum v10 v11 v12) ts']])
        \/
        (exists ds' sm' ts' mscs' dstfile',
        LOG.idempred (FSXPLog fsxp) (SB.rep fsxp) ds' hm' *
        [[ treeseq_in_ds (crash_xform v2) (BFileCrash.flist_crash_xform v3)
            fsxp sm' mscs' ts' ds' ]] *
        [[ treeseq_pred (tree_rep (flatmem_crash_xform v4) v5 
            [temp_fn] srcinum v6 tinum v10 v11 dstfile') ts' ]] *
        [[ file_crash v12 dstfile' ]]))]])%pred); simpl.

    cancel; eauto.
    rewrite crash_xform_sep_star_dist; rewrite H3.
    cancel; eauto.
    rewrite crash_xform_or_dist; or_l; eauto.
    
    unfold pimpl; intros.
    apply crash_xform_sep_star_dist in H. 
    rewrite crash_xform_lift_empty in H.
    rewrite crash_xform_exists_comm in H; destruct_lift H.
    apply crash_xform_sep_star_dist in H.
    rewrite crash_xform_lift_empty in H.
    destruct_lift H.
    specialize (H13 _ H) as Hx.
    rewrite crash_xform_or_dist in Hx.
    apply sep_star_or_distr in Hx; apply pimpl_or_apply in Hx; destruct Hx.
    
    -
    repeat (rewrite crash_xform_exists_comm in H0; destruct_lift H0).
    repeat (rewrite crash_xform_sep_star_dist in H0;
        rewrite crash_xform_lift_empty in H0;
        destruct_lift H0).
    rewrite LOG.idempred_idem in H0.
    destruct_lift H0.
    rewrite SB.crash_xform_rep in H0.
    
    repeat eexists.
    repeat rewrite <- sep_star_assoc.
    repeat apply sep_star_lift_apply'; intros; eauto.

    specialize (H1 r_).
    eapply pimpl_ok2; eauto.
    simpl; cancel; eauto.
    or_l; cancel; eauto.
    or_r; cancel; eauto.
    
    eexists.
    apply sep_star_lift_apply'.
    destruct_lift H14; eauto.
    intros.
    apply crash_xform_sep_star_dist in H15.
    rewrite H3 in H15.
    pred_apply; cancel.
    unfold pimpl; intros m2 Hp; apply H5 in Hp; pred_apply; cancel.
    rewrite crash_xform_or_dist; cancel.
    rewrite crash_xform_or_dist; or_l; xcrash; eauto.
    rewrite crash_xform_or_dist; or_r; xcrash; eauto.
    
    -
    repeat (rewrite crash_xform_exists_comm in H0; destruct_lift H0).
    repeat (rewrite crash_xform_sep_star_dist in H0;
            rewrite crash_xform_lift_empty in H0;
            destruct_lift H0).
    rewrite LOG.idempred_idem in H0.
    destruct_lift H0.
    rewrite SB.crash_xform_rep in H0.
    
    repeat eexists.
    repeat rewrite <- sep_star_assoc.
    repeat apply sep_star_lift_apply'; intros; eauto.

    specialize (H1 r_).
    eapply pimpl_ok2; eauto.
    simpl; cancel; eauto.
    or_l; cancel; eauto.
    or_r; cancel. eauto.
    
    apply treeseq_in_ds_crash_idem; eauto.
    apply treeseq_pred_tree_rep_recover_idem; eauto.
    
    eexists.
    apply sep_star_lift_apply'.
    destruct_lift H14; eauto.
    intros.
    apply crash_xform_sep_star_dist in H15.
    rewrite H3 in H15.
    pred_apply; cancel.
    unfold pimpl; intros m2 Hp; apply H5 in Hp; pred_apply; cancel.
    rewrite crash_xform_or_dist; cancel.
    rewrite crash_xform_or_dist; or_r; xcrash; eauto.
    rewrite crash_xform_or_dist; or_r; xcrash.
    apply treeseq_in_ds_crash_idem; eauto.
    apply treeseq_pred_tree_rep_idem; eauto.
    eapply file_crash_trans; eauto.
Qed.

  Theorem copy_and_rename_with_recover_ok : forall fsxp srcinum tinum (dstbase: list string) (dstname:string) mscs,
    {X<< Fm Ftop Ftree ds sm ts srcpath file dstfile tfile v0,
    PRE:hm
     LOG.rep (FSXPLog fsxp) (SB.rep fsxp) (LOG.NoTxn ds) (MSLL mscs) sm hm *
      [[ treeseq_in_ds Fm Ftop fsxp sm mscs ts ds ]] *
      [[ treeseq_pred (treeseq_safe [temp_fn] (MSAlloc mscs) (ts !!)) ts ]] *
      [[ treeseq_pred (tree_rep Ftree srcpath [temp_fn] srcinum file tinum dstbase dstname dstfile) ts ]] *
      [[ tree_with_tmp Ftree srcpath [temp_fn] srcinum file tinum
                tfile dstbase dstname dstfile (dir2flatmem2 (TStree ts!!)) ]] *
      [[[ DFData file ::: (Off0 |-> v0) ]]] *
      [[ dirtree_inum (TStree ts!!) = the_dnum ]]
    POST:hm' RET:^(mscs', r)
      exists ds' sm' ts',
       LOG.rep (FSXPLog fsxp) (SB.rep fsxp) (LOG.NoTxn ds') (MSLL mscs') sm' hm' *
       [[ treeseq_in_ds Fm Ftop fsxp sm' mscs' ts' ds' ]] *
       [[ treeseq_pred (tree_rep Ftree srcpath [temp_fn] srcinum file tinum dstbase dstname dstfile) ts' ]] *
       (([[r = false ]] *
        (exists f',
         [[ tree_with_tmp Ftree srcpath [temp_fn] srcinum file tinum
                f' dstbase dstname dstfile (dir2flatmem2 (TStree ts'!!)) ]])) \/
       ([[r = true ]] *
          [[ tree_with_dst Ftree srcpath [temp_fn] srcinum file dstbase dstname (dir2flatmem2 (TStree ts'!!)) ]]))
    REC:hm' RET:r
      [[ isError r ]] * any \/
      exists d sm' t mscs',
      [[ r = OK (mscs', fsxp) ]] *
      LOG.rep (FSXPLog fsxp) (SB.rep fsxp) (LOG.NoTxn (d, nil)) (MSLL mscs') sm' hm' *
      [[ treeseq_in_ds (crash_xform Fm) (BFileCrash.flist_crash_xform Ftop) fsxp sm' mscs' (t, nil) (d, nil) ]] *
      [[ treeseq_pred (tree_rep_recover (flatmem_crash_xform Ftree) srcpath [temp_fn] srcinum file dstbase dstname dstfile) (t, nil) ]]
    >>X} copy_and_rename fsxp srcinum tinum dstbase dstname mscs >> atomic_cp_recover.
  Proof.
    unfold forall_helper; intros.
    eapply pimpl_ok3; intros.
    eapply corr3_from_corr2_rx.
    apply copy_and_rename_ok.
    apply atomic_cp_recover_ok.
    safecancel.
    eauto.
    eauto.
    eauto.
    eauto.
    eauto.
    eauto.
    step.

    eassign_idempred.
    
  Admitted.