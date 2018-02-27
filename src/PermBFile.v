Require Import Arith.
Require Import Pred Mem.
Require Import Word.
Require Import Omega.
Require Import List ListUtils.
Require Import Bool.
Require Import Eqdep_dec.
Require Import Setoid.
Require Import Rec.
Require Import FunctionalExtensionality.
Require Import NArith.
Require Import WordAuto.
Require Import ListPred.
Require Import Errno.
Require Import Lock.
Require Import MSets.
Require Import FMapAVL.
Require Import FMapMem.
Require Import MapUtils.
Require Import Structures.OrderedType.
Require Import Structures.OrderedTypeEx.
Require Import StringUtils.

Require Import PermBalloc.
Require Import FSLayout.
Require Import PermInode.
Require Import GenSepAuto.
Require Import PermDiskSet.

Import ListNotations.

Set Implicit Arguments.

(** BFILE is a block-based file implemented on top of the log and the
inode representation. The API provides reading/writing single blocks,
changing the size of the file, and managing file attributes (which are
the same as the inode attributes). *)

Module Dcache := FMapAVL.Make(String_as_OT).
Module DcacheDefs := MapDefs String_as_OT Dcache.
Definition Dcache_type := Dcache.t (addr * bool).

Module BFcache := AddrMap.Map.
Module AddrMap := AddrMap.
Definition BFcache_type := BFcache.t (Dcache_type * addr).
Module BFM := MapMem Nat_as_OT BFcache.

Import AddrMap.
Import AddrSet.
Definition DBlocks_type := Map.t (SS.t).
Module M := MapMem Nat_as_OT Map.
Module BFILE.


  Record memstate := mk_memstate {
    MSAlloc : bool;         (* which block allocator to use? *)
    MSLL : LOG.memstate;    (* lower-level state *)
    MSAllocC: (BALLOCC.BmapCacheType * BALLOCC.BmapCacheType);
    MSIAllocC : IAlloc.BmapCacheType;
    MSICache : INODE.IRec.Cache_type;
    MSCache : BFcache_type;
    MSDBlocks: DBlocks_type;
  }.

  Definition ms_empty msll : memstate := mk_memstate
    true
    msll
    (BALLOCC.Alloc.freelist0, BALLOCC.Alloc.freelist0)
    IAlloc.Alloc.freelist0
    INODE.IRec.cache0
    (BFcache.empty _) (Map.empty _).

  Definition MSinitial ms :=
    MSAlloc ms = true /\
    MSAllocC ms = (BALLOCC.Alloc.freelist0, BALLOCC.Alloc.freelist0) /\
    MSIAllocC ms = IAlloc.Alloc.freelist0 /\
    MSICache ms = INODE.IRec.cache0 /\
    MSCache ms = (BFcache.empty _) /\
    MSDBlocks ms = (Map.empty _).

  Definition MSIAlloc ms :=
    IAlloc.mk_memstate (MSLL ms) (MSIAllocC ms).

  (* interface implementation *)

  Definition getlen lxp ixp inum fms :=
    let '(al, ms, alc, ialc, icache, cache, dblocks) := (MSAlloc fms, MSLL fms, MSAllocC fms, MSIAllocC fms, MSICache fms, MSCache fms, MSDBlocks fms) in
    let^ (icache, ms, n) <- INODE.getlen lxp ixp inum icache ms;;
    Ret ^(mk_memstate al ms alc ialc icache cache dblocks, n).

  Definition getattrs lxp ixp inum fms :=
    let '(al, ms, alc, ialc, icache, cache, dblocks) := (MSAlloc fms, MSLL fms, MSAllocC fms, MSIAllocC fms, MSICache fms, MSCache fms, MSDBlocks fms) in
    let^ (icache, ms, n) <- INODE.getattrs lxp ixp inum icache ms;;
    Ret ^(mk_memstate al ms alc ialc icache cache dblocks, n).

  Definition setattrs lxp ixp inum a fms :=
    let '(al, ms, alc, ialc, icache, cache, dblocks) := (MSAlloc fms, MSLL fms, MSAllocC fms, MSIAllocC fms, MSICache fms, MSCache fms, MSDBlocks fms) in
    let^ (icache, ms) <- INODE.setattrs lxp ixp inum a icache ms;;
    Ret (mk_memstate al ms alc ialc icache cache dblocks).

  Definition updattr lxp ixp inum kv fms :=
    let '(al, ms, alc, ialc, icache, cache, dblocks) := (MSAlloc fms, MSLL fms, MSAllocC fms, MSIAllocC fms, MSICache fms, MSCache fms, MSDBlocks fms) in
    let^ (icache, ms) <- INODE.updattr lxp ixp inum kv icache ms;;
    Ret (mk_memstate al ms alc ialc icache cache dblocks).

  Definition read lxp ixp inum off fms :=
    let '(al, ms, alc, ialc, icache, cache, dblocks) := (MSAlloc fms, MSLL fms, MSAllocC fms, MSIAllocC fms, MSICache fms, MSCache fms, MSDBlocks fms) in
    let^ (icache, ms, bn) <-INODE.getbnum lxp ixp inum off icache ms;;
    let^ (ms, v) <- LOG.read lxp (# bn) ms;;
    Ret ^(mk_memstate al ms alc ialc icache cache dblocks, v).

  Definition get_dirty inum (dblocks : DBlocks_type) :=
    match Map.find inum dblocks with
    | None => SS.empty
    | Some l => l
    end.

  Definition put_dirty inum bn (dblocks : DBlocks_type) :=
    let dirty := get_dirty inum dblocks in
    Map.add inum (SS.add bn dirty) dblocks.

  Definition remove_dirty inum bns (dblocks : DBlocks_type) :=
    match Map.find inum dblocks with
    | None => dblocks
    | Some dirty =>
      let dirty' := (fold_right SS.remove dirty bns) in
      Map.add inum dirty dblocks
    end.

  Definition clear_dirty inum (dblocks : DBlocks_type) :=
    Map.remove inum dblocks.

  Definition write lxp ixp inum off h fms :=
    let '(al, ms, alc, ialc, icache, cache, dblocks) := (MSAlloc fms, MSLL fms, MSAllocC fms, MSIAllocC fms, MSICache fms, MSCache fms, MSDBlocks fms) in
    let^ (icache, ms, bn) <-INODE.getbnum lxp ixp inum off icache ms;;
    ms <- LOG.write lxp (# bn) h ms;;
    Ret (mk_memstate al ms alc ialc icache cache dblocks).

  Definition dwrite lxp ixp inum off h fms :=
(*     t1 <- Rdtsc; *)
    let '(al, ms, alc, ialc, icache, cache, dblocks) := (MSAlloc fms, MSLL fms, MSAllocC fms, MSIAllocC fms, MSICache fms, MSCache fms, MSDBlocks fms) in
    let^ (icache, ms, bn) <- INODE.getbnum lxp ixp inum off icache ms;;
    ms <- LOG.dwrite lxp (# bn) h ms;;
    let dblocks := put_dirty inum (# bn) dblocks in
(*     t2 <- Rdtsc;
    Debug "BFILE.dwrite" (t2 - t1);; *)
    Ret (mk_memstate al ms alc ialc icache cache dblocks).

  Definition datasync lxp (ixp : INODE.IRecSig.xparams) inum fms :=
    let '(al, ms, alc, ialc, icache, cache, dblocks) := (MSAlloc fms, MSLL fms, MSAllocC fms, MSIAllocC fms, MSICache fms, MSCache fms, MSDBlocks fms) in
(*     t1 <- Rdtsc; *)
    let bns := (SS.elements (get_dirty inum dblocks)) in
    ms <- LOG.dsync_vecs lxp bns ms;;
    let dblocks := clear_dirty inum dblocks in
(*     t2 <- Rdtsc;
    Debug "BFILE.datasync" (t2 - t1);; *)
    Ret (mk_memstate al ms alc ialc icache cache dblocks).

  Definition sync lxp (ixp : INODE.IRecSig.xparams) fms :=
    let '(al, ms, alc, ialc, icache, cache, dblocks) := (MSAlloc fms, MSLL fms, MSAllocC fms, MSIAllocC fms, MSICache fms, MSCache fms, MSDBlocks fms) in
    ms <- LOG.flushall lxp ms;;
    Ret (mk_memstate (negb al) ms alc ialc icache cache dblocks).

  Definition sync_noop lxp (ixp : INODE.IRecSig.xparams) fms :=
    let '(al, ms, alc, ialc, icache, cache, dblocks) := (MSAlloc fms, MSLL fms, MSAllocC fms, MSIAllocC fms, MSICache fms, MSCache fms, MSDBlocks fms) in
    ms <- LOG.flushall_noop lxp ms;;
    Ret (mk_memstate (negb al) ms alc ialc icache cache dblocks).

  Definition pick_balloc A (a : A * A) (flag : bool) :=
    if flag then fst a else snd a.

  Definition upd_balloc A (a : A * A) (new : A) (flag : bool) :=
    (if flag then new else fst a,
     if flag then snd a else new).

  Theorem pick_upd_balloc_negb : forall A flag p (new : A),
    pick_balloc p flag = pick_balloc (upd_balloc p new (negb flag)) flag.
  Proof.
    destruct flag, p; intros; reflexivity.
  Qed.

  Theorem pick_negb_upd_balloc : forall A flag p (new : A),
    pick_balloc p (negb flag) = pick_balloc (upd_balloc p new flag) (negb flag).
  Proof.
    destruct flag, p; intros; reflexivity.
  Qed.

  Theorem pick_upd_balloc_lift : forall A flag p (new : A),
    new = pick_balloc (upd_balloc p new flag) flag.
  Proof.
    destruct flag, p; intros; reflexivity.
  Qed.

  Definition grow lxp bxps ixp inum h fms :=
    let '(al, ms, alc, ialc, icache, cache, dblocks) := (MSAlloc fms, MSLL fms, MSAllocC fms, MSIAllocC fms, MSICache fms, MSCache fms, MSDBlocks fms) in
    let^ (icache, ms, len) <- INODE.getlen lxp ixp inum icache ms;;
    If (lt_dec len INODE.NBlocks) {
      let^ (cms, r) <- BALLOCC.alloc lxp (pick_balloc bxps al) (BALLOCC.mk_memstate ms (pick_balloc alc al));;
      match r with
      | None => Ret ^(mk_memstate al (BALLOCC.MSLog cms) (upd_balloc alc (BALLOCC.MSCache cms) al) ialc icache cache dblocks, Err ENOSPCBLOCK)
      | Some bn =>
           let^ (icache, cms, succ) <- INODE.grow lxp (pick_balloc bxps al) ixp inum bn icache cms;;
           match succ with
           | Err e =>
             Ret ^(mk_memstate al (BALLOCC.MSLog cms) (upd_balloc alc (BALLOCC.MSCache cms) al) ialc icache cache dblocks, Err e)
           | OK _ =>
             ms <- LOG.write lxp bn h (BALLOCC.MSLog cms);;
             let dblocks := put_dirty inum bn dblocks in
             Ret ^(mk_memstate al ms (upd_balloc alc (BALLOCC.MSCache cms) al) ialc icache cache dblocks, OK tt)
           end
      end
    } else {
      Ret ^(mk_memstate al ms alc ialc icache cache dblocks, Err EFBIG)
    }.

  Definition shrink lxp bxps ixp inum nr fms :=
    let '(al, ms, alc, ialc, icache, cache, dblocks) := (MSAlloc fms, MSLL fms, MSAllocC fms, MSIAllocC fms, MSICache fms, MSCache fms, MSDBlocks fms) in
    let^ (icache, ms, bns) <- INODE.getallbnum lxp ixp inum icache ms;;
    let l := map (@wordToNat _) (skipn ((length bns) - nr) bns) in
    let dblocks := remove_dirty inum l dblocks in
    cms <- BALLOCC.freevec lxp (pick_balloc bxps (negb al)) l (BALLOCC.mk_memstate ms (pick_balloc alc (negb al)));;
    let^ (icache, cms) <- INODE.shrink lxp (pick_balloc bxps (negb al)) ixp inum nr icache cms;;
    Ret (mk_memstate al (BALLOCC.MSLog cms) (upd_balloc alc (BALLOCC.MSCache cms) (negb al)) ialc icache cache dblocks).

  Definition shuffle_allocs lxp bxps ms cms :=
    let^ (ms, cms) <- ForN 1 <= i < (BmapNBlocks (fst bxps) * valulen / 2)
    Blockmem bm
    Hashmap hm
    Ghost [ F Fm Fs crash m0 sm ]
    Loopvar [ ms cms ]
    Invariant
         exists m' frees,
         LOG.rep lxp F (LOG.ActiveTxn m0 m') ms sm bm hm *
         [[[ m' ::: (Fm * BALLOCC.rep (fst bxps) (fst frees) (BALLOCC.mk_memstate ms (fst cms))   *
                         BALLOCC.rep (snd bxps) (snd frees) (BALLOCC.mk_memstate ms (snd cms))) ]]] *
         [[ (Fs * BALLOCC.smrep (fst frees) * BALLOCC.smrep (snd frees))%pred sm ]] *
         [[ forall bn, bn < (BmapNBlocks (fst bxps)) * valulen /\ bn >= i
             -> In bn (fst frees) ]]
    OnCrash crash
    Begin
      fcms <- BALLOCC.steal lxp (fst bxps) i (BALLOCC.mk_memstate ms (fst cms));;
      scms <- BALLOCC.free lxp (snd bxps) i (BALLOCC.mk_memstate (BALLOCC.MSLog fcms) (snd cms));;
      Ret ^((BALLOCC.MSLog scms), ((BALLOCC.MSCache fcms), (BALLOCC.MSCache scms)))
    Rof ^(ms, cms);;
    Ret ^(ms, cms).

  Definition init lxp bxps bixp ixp ms :=
    fcms <- BALLOCC.init_nofree lxp (snd bxps) ms;;
    scms <- BALLOCC.init lxp (fst bxps) (BALLOCC.MSLog fcms);;
    ialc_ms <- IAlloc.init lxp bixp (BALLOCC.MSLog scms);;
    ms <- INODE.init lxp ixp (IAlloc.Alloc.MSLog ialc_ms);;
    let^ (ms, cms) <- shuffle_allocs lxp bxps ms (BALLOCC.MSCache scms, BALLOCC.MSCache fcms);;
    Ret (mk_memstate true ms cms (IAlloc.MSCache ialc_ms) INODE.IRec.cache0 (BFcache.empty _) (Map.empty _)).

  Definition recover ms :=
    Ret (mk_memstate true ms (BALLOCC.Alloc.freelist0, BALLOCC.Alloc.freelist0) IAlloc.Alloc.freelist0 INODE.IRec.cache0 (BFcache.empty _) (Map.empty _)).

  Definition cache_get inum fms :=
    let '(al, ms, alc, ialc, icache, cache, dblocks) := (MSAlloc fms, MSLL fms, MSAllocC fms, MSIAllocC fms, MSICache fms, MSCache fms, MSDBlocks fms) in
    Ret ^(mk_memstate al ms alc ialc icache cache dblocks, BFcache.find inum cache).

  Definition cache_put inum dc fms :=
    let '(al, ms, alc, ialc, icache, cache, dblocks) := (MSAlloc fms, MSLL fms, MSAllocC fms, MSIAllocC fms, MSICache fms, MSCache fms, MSDBlocks fms) in
    Ret (mk_memstate al ms alc ialc icache (BFcache.add inum dc cache) dblocks).


  (* rep invariants *)

  Definition attr := INODE.iattr.
  Definition attr0 := INODE.iattr0.

  Definition datatype := valuset.

  Record bfile := mk_bfile {
    BFData : list datatype;
    BFAttr : attr;
    BFCache : option (Dcache_type * addr)
  }.

  Definition bfile0 := mk_bfile nil attr0 None.
  Definition freepred f := f = bfile0.

  Definition smrep_single (dirty : SS.t) (i : INODE.inode) : @pred _ addr_eq_dec bool :=
    ( [[ SS.For_all (fun bn => In bn (map (@wordToNat _) (INODE.IBlocks i))) dirty ]] *
    listpred (fun bn => exists b, (# bn) |-> b  * [[ ~SS.In (# bn) dirty -> b = true ]]) (INODE.IBlocks i))%pred.

  Definition smrep_single_helper dblocks i ino :=
    let dirty := match Map.find i dblocks with Some d => d | None => SS.empty end in
    smrep_single dirty ino.

  Definition smrep frees (dirty : Map.t (SS.t)) (ilist : list INODE.inode) :=
    (BALLOCC.smrep (fst frees) * BALLOCC.smrep (snd frees) * arrayN (smrep_single_helper dirty) 0 ilist)%pred.

  Definition file_match f i : @pred _ addr_eq_dec datatype :=
    (listmatch (fun v a => a |-> v ) (BFData f) (map (@wordToNat _) (INODE.IBlocks i)) *
     [[ BFAttr f = INODE.IAttr i ]])%pred.

  Definition cache_ptsto inum (oc : option (Dcache_type * addr)) : @pred _ addr_eq_dec _ :=
    ( match oc with
      | None => emp
      | Some c => inum |-> c
      end )%pred.

  Definition filter_cache (f : bfile ) :=
    match BFCache f with
    | Some v => Some (fst v)
    | None => None
    end.

  Definition cache_rep mscache (flist : list bfile) (ilist : list INODE.inode) :=
     arrayN cache_ptsto 0 (map BFCache flist) (BFM.mm _ mscache).

  Definition rep (bxps : balloc_xparams * balloc_xparams) sm ixp (flist : list bfile) ilist frees cms mscache icache dblocks :=
    (exists lms IFs,
     BALLOCC.rep (fst bxps) (fst frees) (BALLOCC.mk_memstate lms (fst cms)) *
     BALLOCC.rep (snd bxps) (snd frees) (BALLOCC.mk_memstate lms (snd cms)) *
     INODE.rep (fst bxps) IFs ixp ilist icache *
     listmatch file_match flist ilist *
     [[ locked (cache_rep mscache flist ilist) ]] *
     [[ BmapNBlocks (fst bxps) = BmapNBlocks (snd bxps) ]] *
     exists Fs, [[ (Fs * IFs * smrep frees dblocks ilist)%pred sm ]]
    )%pred.


  Definition rep_length_pimpl : forall bxps sm ixp flist ilist frees allocc icache mscache dblocks,
    rep bxps sm ixp flist ilist frees allocc icache mscache dblocks =p=>
    (rep bxps sm ixp flist ilist frees allocc icache mscache dblocks *
     [[ length flist = ((INODE.IRecSig.RALen ixp) * INODE.IRecSig.items_per_val)%nat ]] *
     [[ length ilist = ((INODE.IRecSig.RALen ixp) * INODE.IRecSig.items_per_val)%nat ]])%pred.
  Proof.
    unfold rep; intros.
    norm'l; unfold stars; simpl.
    rewrite INODE.rep_length_pimpl at 1.
    rewrite listmatch_length_pimpl at 1.
    cancel.
  Qed.

  Definition rep_alt (bxps : BALLOCC.Alloc.Alloc.BmpSig.xparams * BALLOCC.Alloc.Alloc.BmpSig.xparams)
                     sm ixp (flist : list bfile) ilist frees cms icache mscache msalloc dblocks :=
    (exists lms IFs,
      BALLOCC.rep (pick_balloc bxps msalloc) (pick_balloc frees msalloc) (BALLOCC.mk_memstate lms (pick_balloc cms msalloc)) *
     BALLOCC.rep (pick_balloc bxps (negb msalloc)) (pick_balloc frees (negb msalloc)) (BALLOCC.mk_memstate lms (pick_balloc cms (negb msalloc))) *
     INODE.rep (pick_balloc bxps msalloc) IFs ixp ilist icache *
     listmatch file_match flist ilist *
     [[ locked (cache_rep mscache flist ilist) ]] *
     [[ BmapNBlocks (pick_balloc bxps msalloc) = BmapNBlocks (pick_balloc bxps (negb msalloc)) ]] *
     exists Fs, [[ (Fs * IFs * smrep (pick_balloc frees (msalloc), pick_balloc frees (negb msalloc)) dblocks ilist)%pred sm ]]
    )%pred.

  Theorem rep_alt_equiv : forall bxps sm ixp flist ilist frees mscache allocc icache msalloc dblocks,
    rep bxps sm ixp flist ilist frees allocc mscache icache dblocks <=p=> rep_alt bxps sm ixp flist ilist frees allocc icache mscache msalloc dblocks.
  Proof.
    unfold rep, rep_alt; split; destruct msalloc; simpl.
    - cancel.
    - norml; unfold stars; simpl.
      rewrite INODE.rep_bxp_switch at 1 by eauto.
      cancel.
      unfold smrep. cancel.
    - cancel.
    - norml; unfold stars; simpl.
      rewrite INODE.rep_bxp_switch at 1 by eauto.
      cancel.
      unfold smrep. cancel.
  Qed.

  Definition clear_cache bf := mk_bfile (BFData bf) (BFAttr bf) None.
  Definition clear_caches bflist := map clear_cache bflist.

  Theorem rep_clear_freelist : forall bxps sm ixp flist ilist frees allocc mscache icache dblocks,
    rep bxps sm ixp flist ilist frees allocc mscache icache dblocks =p=>
    rep bxps sm ixp flist ilist frees (BALLOCC.Alloc.freelist0, BALLOCC.Alloc.freelist0) mscache icache dblocks.
  Proof.
    unfold rep; intros; cancel.
    rewrite <- BALLOCC.rep_clear_mscache_ok. cancel.
    rewrite <- BALLOCC.rep_clear_mscache_ok. cancel.
  Qed.

  Theorem rep_clear_bfcache : forall bxps sm ixp flist ilist frees allocc mscache icache dblocks,
    rep bxps sm ixp flist ilist frees allocc mscache icache dblocks =p=>
    rep bxps sm ixp (clear_caches flist) ilist frees allocc (BFcache.empty _) icache dblocks.
  Proof.
    unfold rep; intros; cancel.
    unfold clear_caches.
    rewrite listmatch_map_l.
    unfold file_match, clear_cache; simpl.
    reflexivity.

    rewrite locked_eq.
    unfold cache_rep, clear_caches, clear_cache.
    rewrite map_map; simpl.
    denote smrep as Hd. clear Hd.
    denote locked as Hl. clear Hl.
    generalize 0.
    induction flist; simpl; intros.
    apply BFM.mm_init.
    specialize (IHflist (S n)).
    pred_apply; cancel.
  Unshelve.
    exact unit.
  Qed.

  Theorem rep_clear_icache: forall bxps sm ixp flist ilist frees allocc mscache icache dblocks,
    rep bxps sm ixp flist ilist frees allocc mscache icache dblocks =p=>
    rep bxps sm ixp flist ilist frees allocc mscache INODE.IRec.cache0 dblocks.
  Proof.
    unfold BFILE.rep. cancel.
    apply INODE.rep_clear_cache.
    cancel.
  Qed.

  Lemma smrep_init: forall n,
    emp <=p=> arrayN (smrep_single_helper (Map.empty _)) 0 (repeat INODE.inode0 n).
  Proof.
    intros n.
    generalize 0 as st.
    induction n; cbn; auto.
    intros.
    specialize (IHn (S st)).
    rewrite IHn.
    unfold smrep_single_helper, smrep_single.
    cbn.
    split; cancel.
    unfold SS.For_all. intros.
    rewrite <- SetFacts.empty_iff; eauto.
  Qed.

  Definition block_belong_to_file ilist bn inum off :=
    off < length (INODE.IBlocks (selN ilist inum INODE.inode0)) /\
    bn = # (selN (INODE.IBlocks (selN ilist inum INODE.inode0)) off $0).

  Definition block_is_unused freeblocks (bn : addr) := In bn freeblocks.

  Definition block_is_unused_dec freeblocks (bn : addr) :
    { block_is_unused freeblocks bn } + { ~ block_is_unused freeblocks bn }
    := In_dec addr_eq_dec bn freeblocks.

  Lemma block_is_unused_xor_belong_to_file : forall F Ftop fsxp sm files ilist free allocc mscache icache dblocks m flag bn inum off,
    (F * rep fsxp sm Ftop files ilist free allocc mscache icache dblocks)%pred m ->
    block_is_unused (pick_balloc free flag) bn ->
    block_belong_to_file ilist bn inum off ->
    False.
  Proof.
    unfold rep, block_is_unused, block_belong_to_file; intuition.
    rewrite <- locked_eq with (x := bn) in H3.
    destruct_lift H.
    rewrite listmatch_isolate with (i := inum) in H.
    unfold file_match at 2 in H.
    erewrite listmatch_isolate with (i := off) (a := (BFData files ⟦ inum ⟧)) in H by simplen.
    erewrite selN_map in H; eauto.
    unfold BALLOCC.rep in H; destruct_lift H.
    unfold BALLOCC.Alloc.rep in H; destruct_lift H.
    unfold BALLOCC.Alloc.Alloc.rep in H; destruct_lift H.
    destruct flag; simpl in *.
    - denote (locked _ = _) as Hl.
      rewrite locked_eq in Hl.
      rewrite <- Hl in H; clear Hl.
      match goal with H: context [ptsto bn ?a], Hl: _ <=p=> _ |- _ =>
        rewrite Hl, listpred_pick in H by eauto; destruct_lift H
      end.
      eapply ptsto_conflict_F with (m := m) (a := bn).
      pred_apply.
      cancel.
    - denote (locked _ = _) as Hl.
      rewrite locked_eq in Hl.
      rewrite <- Hl in H; clear Hl.
      match goal with H: context [ptsto bn ?a], Hl: _ <=p=> _ |- _ =>
        rewrite Hl, listpred_pick in H by eauto; destruct_lift H
      end.
      eapply ptsto_conflict_F with (m := m) (a := bn).
      pred_apply.
      cancel.
    - erewrite listmatch_length_r; eauto.
      destruct (lt_dec inum (length ilist)); eauto.
      rewrite selN_oob in * by omega.
      unfold INODE.inode0 in H2; simpl in *; omega.
    - destruct (lt_dec inum (length ilist)); eauto.
      rewrite selN_oob in * by omega.
      unfold INODE.inode0 in *; simpl in *; omega.
  Grab Existential Variables.
    all: eauto.
    all: solve [exact valuset0 | exact bfile0].
  Qed.

  Definition ilist_safe ilist1 free1 ilist2 free2 :=
    incl free2 free1 /\
    forall inum off bn,
        block_belong_to_file ilist2 bn inum off ->
        (block_belong_to_file ilist1 bn inum off \/
         block_is_unused free1 bn).

  Theorem ilist_safe_refl : forall i f,
    ilist_safe i f i f.
  Proof.
    unfold ilist_safe; intuition.
  Qed.
  Local Hint Resolve ilist_safe_refl.

  Theorem ilist_safe_trans : forall i1 f1 i2 f2 i3 f3,
    ilist_safe i1 f1 i2 f2 ->
    ilist_safe i2 f2 i3 f3 ->
    ilist_safe i1 f1 i3 f3.
  Proof.
    unfold ilist_safe; intros.
    destruct H.
    destruct H0.
    split.
    - eapply incl_tran; eauto.
    - intros.
      specialize (H2 _ _ _ H3).
      destruct H2; eauto.
      right.
      unfold block_is_unused in *.
      eauto.
  Qed.

  Theorem ilist_safe_upd_nil : forall ilist frees i off,
    INODE.IBlocks i = nil ->
    ilist_safe ilist frees (updN ilist off i) frees.
  Proof.
    intros.
    destruct (lt_dec off (length ilist)).
    - unfold ilist_safe, block_belong_to_file.
      intuition auto.
      destruct (addr_eq_dec off inum); subst.
      rewrite selN_updN_eq in * by auto.
      rewrite H in *; cbn in *; omega.
      rewrite selN_updN_ne in * by auto.
      intuition auto.
    - rewrite updN_oob by omega; auto.
  Qed.

  Lemma block_belong_to_file_inum_ok : forall ilist bn inum off,
    block_belong_to_file ilist bn inum off ->
    inum < length ilist.
  Proof.
    intros.
    destruct (lt_dec inum (length ilist)); eauto.
    unfold block_belong_to_file in *.
    rewrite selN_oob in H by omega.
    simpl in H.
    omega.
  Qed.

  Lemma rep_used_block_eq_Some_helper : forall T (x y: T),
    Some x = Some y -> x = y.
  Proof.
    intros.
    inversion H.
    auto.
  Qed.

  Theorem rep_used_block_eq : forall F bxps sm ixp flist ilist m bn inum off frees allocc mscache icache dblocks,
    (F * rep bxps sm ixp flist ilist frees allocc mscache icache dblocks)%pred (list2nmem m) ->
    block_belong_to_file ilist bn inum off ->
    selN (BFData (selN flist inum bfile0)) off valuset0 = selN m bn valuset0.
  Proof.
    unfold rep; intros.
    destruct_lift H.
    rewrite listmatch_length_pimpl in H; destruct_lift H.
    rewrite listmatch_extract with (i := inum) in H.
    2: substl (length flist); eapply block_belong_to_file_inum_ok; eauto.

    assert (inum < length ilist) by ( eapply block_belong_to_file_inum_ok; eauto ).
    assert (inum < length flist) by ( substl (length flist); eauto ).

    denote block_belong_to_file as Hx; assert (Hy := Hx).
    unfold block_belong_to_file in Hy; intuition.
    unfold file_match at 2 in H.
    rewrite listmatch_length_pimpl with (a := BFData _) in H; destruct_lift H.
    denote! (length _ = _) as Heq.
    rewrite listmatch_extract with (i := off) (a := BFData _) in H.
    2: rewrite Heq; rewrite map_length; eauto.

    erewrite selN_map in H; eauto.
    eapply rep_used_block_eq_Some_helper.
    apply eq_sym.
    rewrite <- list2nmem_sel_inb.

    eapply ptsto_valid.
    pred_apply.
    eassign (natToWord addrlen O).
    cancel.

    eapply list2nmem_inbound.
    pred_apply.
    cancel.

  Grab Existential Variables.
    all: eauto.
  Qed.

  Lemma smrep_single_helper_put_dirty_oob: forall inum bn dblocks st ino,
    inum <> st ->
    smrep_single_helper (put_dirty inum bn dblocks) st ino <=p=>
    smrep_single_helper dblocks st ino.
  Proof.
    unfold smrep_single_helper.
    unfold put_dirty.
    intros.
    rewrite MapFacts.add_neq_o by auto.
    auto.
  Qed.

  Lemma arrayN_smrep_single_helper_put_dirty_oob: forall ilist st inum bn dblocks,
    inum < st \/ inum >= st + length ilist ->
    arrayN (smrep_single_helper (put_dirty inum bn dblocks)) st ilist <=p=>
    arrayN (smrep_single_helper dblocks) st ilist.
  Proof.
    induction ilist; cbn.
    split; cancel.
    intros.
    rewrite smrep_single_helper_put_dirty_oob by omega.
    rewrite IHilist by omega.
    auto.
  Qed.

  Lemma arrayN_ex_smrep_single_helper_put_dirty: forall ilist inum bn dblocks,
    arrayN_ex (smrep_single_helper (put_dirty inum bn dblocks)) ilist inum <=p=>
    arrayN_ex (smrep_single_helper dblocks) ilist inum.
  Proof.
    unfold arrayN_ex.
    intros.
    destruct (lt_dec inum (length ilist)).
    - rewrite arrayN_smrep_single_helper_put_dirty_oob.
      rewrite arrayN_smrep_single_helper_put_dirty_oob.
      auto.
      autorewrite with core. omega.
      rewrite firstn_length_l; omega.
    - rewrite skipn_oob by omega.
      rewrite firstn_oob by omega.
      rewrite arrayN_smrep_single_helper_put_dirty_oob by omega.
      rewrite arrayN_smrep_single_helper_put_dirty_oob by omega.
      auto.
  Qed.

Lemma selN_NoDup_notin_firstn: forall T (l : list T) i x d,
  i < length l ->
  NoDup l ->
  selN l i d = x ->
  ~In x (firstn i l).
Proof.
  induction l; cbn; intros.
  omega.
  subst.
  destruct i; cbn.
  auto.
  inversion H0; subst.
  intuition subst.
  eapply H3.
  eapply in_selN; omega.
  eapply IHl; eauto; omega.
Qed.

Lemma selN_NoDup_notin_skipn: forall T (l : list T) i x d,
  i < length l ->
  NoDup l ->
  selN l i d = x ->
  ~In x (skipn (S i) l).
Proof.
  induction l; cbn; intros.
  omega.
  subst.
  inversion H0; subst.
  destruct i; cbn.
  auto.
  intuition subst.
  eapply IHl; eauto; omega.
Qed.

Lemma selN_NoDup_notin_removeN: forall T (l : list T) i x d,
  i < length l ->
  selN l i d = x ->
  NoDup l ->
  ~In x (removeN l i).
Proof.
  intros.
  unfold removeN.
  rewrite in_app_iff.
  intuition.
  eapply selN_NoDup_notin_firstn; eauto.
  eapply selN_NoDup_notin_skipn; eauto.
Qed.


  Lemma smrep_single_add: forall dirty ino bn,
    In bn (INODE.IBlocks ino) ->
    smrep_single dirty ino =p=> smrep_single (SS.add #bn dirty) ino.
  Proof.
    unfold smrep_single.
    cancel.
    eapply in_selN_exists in H; deex.
    rewrite listpred_nodup_piff.
    2: eauto using weq.
    cancel.
    eapply listpred_pimpl_replace; cancel.
    intuition.
    destruct_lifts.
    eapply ptsto_conflict with (a := #y) (m := m').
    pred_apply; cancel.
    unfold SS.For_all in *.
    intuition.
    rewrite SS.add_spec in *.
    intuition. subst.
    eapply in_map; auto.
  Unshelve.
    all: apply wzero.
  Qed.


  Lemma smrep_single_helper_put_dirty: forall inum bn dblocks ino,
    In bn (INODE.IBlocks ino) ->
    smrep_single_helper dblocks inum ino =p=>
    smrep_single_helper (put_dirty inum #bn dblocks) inum ino.
  Proof.
    unfold smrep_single_helper.
    unfold put_dirty.
    intros.
    rewrite MapFacts.add_eq_o by auto.
    unfold get_dirty.
    apply smrep_single_add. auto.
  Qed.

  Lemma smrep_upd: forall frees dblocks ilist inum bn,
    goodSize addrlen bn ->
    In $bn (INODE.IBlocks (selN ilist inum INODE.inode0)) ->
    inum < length ilist ->
    smrep frees dblocks ilist =p=> smrep frees (put_dirty inum bn dblocks) ilist.
  Proof.
    unfold smrep.
    intros.
    cancel.
    rewrite arrayN_except with (i := inum) by auto.
    rewrite arrayN_except with (i := inum) by auto.
    rewrite arrayN_ex_smrep_single_helper_put_dirty.
    cancel.
    rewrite smrep_single_helper_put_dirty; eauto.
    rewrite wordToNat_natToWord_idempotent' by eauto.
    cancel.
  Qed.

  Lemma smrep_single_add_new: forall dirty ino ino' bn b,
    INODE.IBlocks ino' = INODE.IBlocks ino ++ [bn] ->
    #bn |->b * smrep_single dirty ino =p=> smrep_single (SS.add #bn dirty) ino'.
  Proof.
    unfold smrep_single.
    cancel.
    rewrite H.
    rewrite listpred_app; cbn.
    cancel.
    apply listpred_pimpl_replace.
    intros.
    eapply in_selN_exists in H1; deex.
    cancel.
    rewrite H.
    unfold SS.For_all in *.
    intros x; intros.
    rewrite map_app.
    apply in_or_app.
    rewrite SS.add_spec in *.
    intuition. subst.
    right.
    cbn; auto.
  Unshelve.
    all: apply wzero.
  Qed.


  Lemma smrep_single_helper_add_dirty: forall inum bn dblocks ino ino' b,
    INODE.IBlocks ino' = INODE.IBlocks ino ++ [bn] ->
    #bn |-> b * smrep_single_helper dblocks inum ino =p=>
    smrep_single_helper (put_dirty inum #bn dblocks) inum ino'.
  Proof.
    unfold smrep_single_helper.
    unfold put_dirty.
    intros.
    rewrite MapFacts.add_eq_o by auto.
    unfold get_dirty.
    eapply smrep_single_add_new; auto.
  Qed.

  Lemma smrep_upd_add: forall frees dblocks ilist ilist' ino' inum bn b,
    goodSize addrlen bn ->
    inum < length ilist ->
    let ino := (selN ilist inum INODE.inode0) in
    ilist' = updN ilist inum ino' ->
    INODE.IBlocks ino' = INODE.IBlocks ino ++ [$bn] ->
    bn |-> b * smrep frees dblocks ilist =p=> smrep frees (put_dirty inum bn dblocks) ilist'.
  Proof.
    unfold smrep.
    intros.
    cancel.
    rewrite arrayN_except with (i := inum) by auto.
    rewrite arrayN_except_upd.
    rewrite arrayN_ex_smrep_single_helper_put_dirty.
    cancel.
    replace bn with (# (@natToWord addrlen bn)) in *.
    rewrite natToWord_wordToNat in *.
    rewrite smrep_single_helper_add_dirty. cancel.
    all: eauto.
    rewrite wordToNat_natToWord_idempotent'; auto.
  Qed.


  Theorem rep_safe_used: forall F bxps sm ixp flist ilist m bn inum off frees allocc mscache icache dblocks v,
    (F * rep bxps sm ixp flist ilist frees allocc mscache icache dblocks)%pred (list2nmem m) ->
    block_belong_to_file ilist bn inum off ->
    let f := selN flist inum bfile0 in
    let f' := mk_bfile (updN (BFData f) off v) (BFAttr f) (BFCache f) in
    let flist' := updN flist inum f' in
    (F * rep bxps sm ixp flist' ilist frees allocc mscache icache dblocks)%pred (list2nmem (updN m bn v)).
  Proof.
    unfold rep; intros.
    destruct_lift H.
    rewrite listmatch_length_pimpl in H; destruct_lift H.
    rewrite listmatch_extract with (i := inum) in H.
    2: substl (length flist); eapply block_belong_to_file_inum_ok; eauto.

    assert (inum < length ilist) by ( eapply block_belong_to_file_inum_ok; eauto ).
    assert (inum < length flist) by ( substl (length flist); eauto ).

    denote block_belong_to_file as Hx; assert (Hy := Hx).
    unfold block_belong_to_file in Hy; intuition.
    unfold file_match at 2 in H.
    rewrite listmatch_length_pimpl with (a := BFData _) in H; destruct_lift H.
    denote! (length _ = _) as Heq.
    rewrite listmatch_extract with (i := off) (a := BFData _) in H.
    2: rewrite Heq; rewrite map_length; eauto.

    erewrite selN_map in H; eauto.

    eapply pimpl_trans; [ apply pimpl_refl | | eapply list2nmem_updN; pred_apply ].
    2: eassign (natToWord addrlen 0).
    2: cancel.

    cancel.

    eapply pimpl_trans.
    2: eapply listmatch_isolate with (i := inum); eauto.
    2: rewrite length_updN; eauto.

    rewrite removeN_updN. cancel.
    unfold file_match; cancel.
    2: rewrite selN_updN_eq by ( substl (length flist); eauto ).
    2: simpl; eauto.

    eapply pimpl_trans.
    2: eapply listmatch_isolate with (i := off).
    2: rewrite selN_updN_eq by ( substl (length flist); eauto ).
    2: simpl.
    2: rewrite length_updN.
    2: rewrite Heq; rewrite map_length; eauto.
    2: rewrite map_length; eauto.

    rewrite selN_updN_eq; eauto; simpl.
    erewrite selN_map by eauto.
    rewrite removeN_updN.
    rewrite selN_updN_eq by ( rewrite Heq; rewrite map_length; eauto ).
    cancel.

    rewrite locked_eq in *; unfold cache_rep in *.
    pred_apply.
    rewrite map_updN.
    erewrite selN_eq_updN_eq by ( erewrite selN_map; eauto; reflexivity ).
    cancel.

  Grab Existential Variables.
    all: eauto.
    all: try exact BFILE.bfile0.
    all: try exact None.
  Qed.

  Theorem rep_safe_unused: forall F bxps sm ixp flist ilist m frees allocc mscache icache dblocks bn v flag,
    (F * rep bxps sm ixp flist ilist frees allocc mscache icache dblocks)%pred (list2nmem m) ->
    block_is_unused (pick_balloc frees flag) bn ->
    (F * rep bxps sm ixp flist ilist frees allocc mscache icache dblocks)%pred (list2nmem (updN m bn v)).
  Proof.
    unfold rep, pick_balloc, block_is_unused; intros.
    destruct_lift H.
    destruct flag.
    - unfold BALLOCC.rep at 1 in H.
      unfold BALLOCC.Alloc.rep in H.
      unfold BALLOCC.Alloc.Alloc.rep in H.
      destruct_lift H.

      denote listpred as Hx.
      assert (Hy := Hx).
      rewrite listpred_nodup_piff in Hy; [ | apply addr_eq_dec | ].

      2: intros; assert (~ (y |->? * y |->?)%pred m') as Hc by apply ptsto_conflict.
      2: contradict Hc; pred_apply; cancel.

      assert (Hnodup := H). rewrite Hy in Hnodup; destruct_lift Hnodup.

      rewrite listpred_remove_piff in Hy; [ | | eauto | eauto ].

      2: intros; assert (~ (y |->? * y |->?)%pred m') as Hc by apply ptsto_conflict.
      2: contradict Hc; pred_apply; cancel.

      rewrite Hy in H.
      destruct_lift H.
      eapply pimpl_trans; [ apply pimpl_refl | | eapply list2nmem_updN; pred_apply; cancel ].
      unfold BALLOCC.rep at 2. unfold BALLOCC.Alloc.rep. unfold BALLOCC.Alloc.Alloc.rep.

      norm; unfold stars; simpl.
      2: intuition eauto.
      cancel. rewrite Hy. cancel.

    - unfold BALLOCC.rep at 2 in H.
      unfold BALLOCC.Alloc.rep in H.
      unfold BALLOCC.Alloc.Alloc.rep in H.
      destruct_lift H.

      denote listpred as Hx.
      assert (Hy := Hx).
      rewrite listpred_nodup_piff in Hy; [ | apply addr_eq_dec | ].

      2: intros; assert (~ (y |->? * y |->?)%pred m') as Hc by apply ptsto_conflict.
      2: contradict Hc; pred_apply; cancel.

      assert (Hnodup := H). rewrite Hy in Hnodup; destruct_lift Hnodup.

      rewrite listpred_remove_piff in Hy; [ | | eauto | eauto ].

      2: intros; assert (~ (y |->? * y |->?)%pred m') as Hc by apply ptsto_conflict.
      2: contradict Hc; pred_apply; cancel.

      rewrite Hy in H.
      destruct_lift H.
      eapply pimpl_trans; [ apply pimpl_refl | | eapply list2nmem_updN; pred_apply; cancel ].
      unfold BALLOCC.rep at 3. unfold BALLOCC.Alloc.rep. unfold BALLOCC.Alloc.Alloc.rep.

      norm; unfold stars; simpl.
      2: intuition eauto.
      cancel. rewrite Hy. cancel.

    Unshelve.
    all: apply addr_eq_dec.
  Qed.

  Theorem block_belong_to_file_bfdata_length : forall bxp sm ixp flist ilist frees allocc mscache icache dblocks m F inum off bn,
    (F * rep bxp sm ixp flist ilist frees allocc mscache icache dblocks)%pred m ->
    block_belong_to_file ilist bn inum off ->
    off < length (BFData (selN flist inum BFILE.bfile0)).
  Proof.
    intros.
    apply block_belong_to_file_inum_ok in H0 as H0'.
    unfold block_belong_to_file, rep in *.
    setoid_rewrite listmatch_extract with (i := inum) in H.
    unfold file_match at 2 in H.
    setoid_rewrite listmatch_length_pimpl with (a := BFData _) in H.
    destruct_lift H.
    rewrite map_length in *.
    intuition.
    denote (length (BFData _)) as Hl.
    rewrite Hl; eauto.
    simplen.
  Unshelve.
    all: try exact bfile0.
  Qed.

  Definition synced_file f := mk_bfile (synced_list (map fst (BFData f))) (BFAttr f) (BFCache f).

  Lemma add_nonzero_exfalso_helper2 : forall a b,
    a * valulen + b = 0 -> a <> 0 -> False.
  Proof.
    intros.
    destruct a; auto.
    rewrite Nat.mul_succ_l in H.
    assert (0 < a * valulen + valulen + b).
    apply Nat.add_pos_l.
    apply Nat.add_pos_r.
    rewrite valulen_is; simpl.
    apply Nat.lt_0_succ.
    omega.
  Qed.

  Lemma file_match_init_ok : forall n,
    emp =p=> listmatch file_match (repeat bfile0 n) (repeat INODE.inode0 n).
  Proof.
    induction n; simpl; intros.
    unfold listmatch; cancel.
    rewrite IHn.
    unfold listmatch; cancel.
    unfold file_match, listmatch; cancel.
  Qed.

  Lemma odd_nonzero : forall n,
    Nat.odd n = true -> n <> 0.
  Proof.
    destruct n; intros; auto.
    cbv in H; congruence.
  Qed.

  Local Hint Resolve odd_nonzero.

  Definition mscs_same_except_log mscs1 mscs2 :=
    (MSAlloc mscs1 = MSAlloc mscs2) /\
    (MSAllocC mscs1 = MSAllocC mscs2) /\
    (MSIAllocC mscs1 = MSIAllocC mscs2) /\
    (MSICache mscs1 = MSICache mscs2) /\
    (MSCache mscs1 = MSCache mscs2) /\
    (MSDBlocks mscs1 = MSDBlocks mscs2).

  Lemma mscs_same_except_log_comm : forall mscs1 mscs2,
    mscs_same_except_log mscs1 mscs2 ->
    mscs_same_except_log mscs2 mscs1.
  Proof.
    firstorder.
  Qed.

  Lemma mscs_same_except_log_refl : forall mscs,
    mscs_same_except_log mscs mscs.
  Proof.
    firstorder.
  Qed.

  Ltac destruct_ands :=
    repeat match goal with
    | [ H: _ /\ _ |- _ ] => destruct H
    end.

  Ltac msalloc_eq :=
    repeat match goal with
    | [ H: mscs_same_except_log _ _ |- _ ] =>
      unfold BFILE.mscs_same_except_log in H; destruct_ands
    | [ H: MSAlloc _ = MSAlloc _ |- _ ] => rewrite H in *; clear H
    | [ H: MSAllocC _ = MSAllocC _ |- _ ] => rewrite H in *; clear H
    | [ H: MSIAllocC _ = MSIAllocC _ |- _ ] => rewrite H in *; clear H
    | [ H: MSCache _ = MSCache _ |- _ ] => rewrite H in *; clear H
    | [ H: MSICache _ = MSICache _ |- _ ] => rewrite H in *; clear H
    | [ H: MSDBlocks _ = MSDBlocks _ |- _ ] => rewrite H in *; clear H
    end.


  (**** automation **)

  Fact resolve_selN_bfile0 : forall l i d,
    d = bfile0 -> selN l i d = selN l i bfile0.
  Proof.
    intros; subst; auto.
  Qed.

  Fact resolve_selN_vs0 : forall l i (d : valuset),
    d = valuset0 -> selN l i d = selN l i valuset0.
  Proof.
    intros; subst; auto.
  Qed.

  Hint Rewrite resolve_selN_bfile0 using reflexivity : defaults.
  Hint Rewrite resolve_selN_vs0 using reflexivity : defaults.

  Lemma bfcache_init' : forall len start,
    arrayN cache_ptsto start (map BFCache (repeat bfile0 len))
      (BFM.mm _ (BFcache.empty _)).
  Proof.
    induction len; simpl; intros.
    eapply BFM.mm_init.
    eapply pimpl_apply; [ | apply IHlen ].
    cancel.
  Qed.

  Lemma bfcache_init : forall len ilist,
    locked (cache_rep (BFcache.empty _) (repeat bfile0 len) ilist).
  Proof.
    intros.
    rewrite locked_eq.
    unfold cache_rep.
    eapply bfcache_init'.
  Qed.

  Lemma bfcache_upd : forall mscache inum flist ilist F f d a,
    locked (cache_rep mscache flist ilist) ->
    (F * inum |-> f)%pred (list2nmem flist) ->
    locked (cache_rep mscache (updN flist inum {| BFData := d; BFAttr := a; BFCache := BFCache f |}) ilist).
  Proof.
    intros.
    rewrite locked_eq in *.
    unfold cache_rep in *.
    rewrite map_updN; simpl.
    eapply list2nmem_sel in H0 as H0'; rewrite H0'.
    erewrite selN_eq_updN_eq; eauto.
    erewrite selN_map; eauto.
    simplen.
  Unshelve.
    exact None.
  Qed.

  Lemma cache_ptsto_none'' : forall l start m idx,
    arrayN cache_ptsto start l m ->
    idx < start ->
    m idx = None.
  Proof.
    induction l; intros; eauto.
    simpl in H.
    eapply sep_star_none; intros; [ | | exact H ].
    destruct a; simpl in *.
    eapply ptsto_none; [ | eauto ]; omega.
    eauto.
    eapply IHl; eauto.
  Qed.

  Lemma cache_ptsto_none' : forall l start m idx def,
    arrayN cache_ptsto start l m ->
    idx < length l ->
    selN l idx def = None ->
    m (start + idx) = None.
  Proof.
    induction l; intros; eauto.
    simpl in H.
    eapply sep_star_none; eauto; intros.
    destruct a; simpl in *.
    eapply ptsto_none; [ | eauto ].
    destruct idx; try omega; try congruence.
    eauto.
    destruct idx.
    eapply cache_ptsto_none''; eauto; omega.
    replace (start + S idx) with (S start + idx) by omega.
    eapply IHl; eauto.
    simpl in *; omega.
  Qed.

  Lemma cache_ptsto_none : forall l m idx def,
    arrayN cache_ptsto 0 l m ->
    idx < length l ->
    selN l idx def = None ->
    m idx = None.
  Proof.
    intros.
    replace (idx) with (0 + idx) by omega.
    eapply cache_ptsto_none'; eauto.
  Qed.

  Lemma cache_ptsto_none_find : forall l c idx def,
    arrayN cache_ptsto 0 l (BFM.mm _ c) ->
    idx < length l ->
    selN l idx def = None ->
    BFcache.find idx c = None.
  Proof.
    intros.
    assert (BFM.mm _ c idx = None).
    eapply cache_ptsto_none; eauto.
    eauto.
  Qed.

  Lemma bfcache_find : forall c flist ilist inum f F,
    locked (cache_rep c flist ilist) ->
    (F * inum |-> f)%pred (list2nmem flist) ->
    BFcache.find inum c = BFCache f.
  Proof.
    intros.
    rewrite locked_eq in *.
    unfold cache_rep in *.
    eapply list2nmem_sel in H0 as H0'.
    case_eq (BFCache f); intros.
    - eapply arrayN_isolate with (i := inum) in H; [ | simplen ].
      unfold cache_ptsto at 2 in H. simpl in H.
      erewrite selN_map in H by simplen. rewrite <- H0' in H. rewrite H1 in H.
      eapply BFM.mm_find; pred_apply; cancel.
    - eapply cache_ptsto_none_find; eauto.
      simplen.
      erewrite selN_map by simplen.
      rewrite <- H0'.
      eauto.
  Unshelve.
    all: exact None.
  Qed.

  Lemma bfcache_put : forall msc flist ilist inum c f F,
    locked (cache_rep msc flist ilist) ->
    (F * inum |-> f)%pred (list2nmem flist) ->
    locked (cache_rep (BFcache.add inum c msc)
                      (updN flist inum {| BFData := BFData f; BFAttr := BFAttr f; BFCache := Some c |})
                      ilist).
  Proof.
    intros.
    rewrite locked_eq in *.
    unfold cache_rep in *.
    eapply list2nmem_sel in H0 as H0'.
    case_eq (BFCache f); intros.
    - eapply pimpl_apply.
      2: eapply BFM.mm_replace.
      rewrite arrayN_isolate with (i := inum) by simplen.
      unfold cache_ptsto at 2; simpl.
      erewrite selN_map by simplen. rewrite selN_updN_eq by simplen. cancel.
      rewrite map_updN. rewrite firstn_updN_oob by omega.
      rewrite skipn_updN by omega.
      pred_apply.
      rewrite arrayN_isolate with (i := inum) by simplen.
      unfold cache_ptsto at 2.
      erewrite selN_map by simplen. rewrite <- H0'. rewrite H1. cancel.
    - eapply pimpl_apply.
      2: eapply BFM.mm_add; eauto.
      rewrite arrayN_isolate with (i := inum) by simplen.
      rewrite arrayN_isolate with (i := inum) (vs := map _ _) by simplen.
      rewrite map_updN. rewrite firstn_updN_oob by omega.
      simpl; rewrite skipn_updN by omega.
      cancel.
      unfold cache_ptsto.
      erewrite selN_map by simplen. rewrite H1.
      rewrite selN_updN_eq by simplen.
      cancel.
      eapply cache_ptsto_none_find; eauto.
      simplen.
      erewrite selN_map by simplen.
      rewrite <- H0'; eauto.
  Unshelve.
    all: try exact None.
    all: eauto.
  Qed.

  Lemma bfcache_remove' : forall msc flist ilist inum f d a F,
    locked (cache_rep msc flist ilist) ->
    (F * inum |-> f)%pred (list2nmem flist) ->
    locked (cache_rep (BFcache.remove inum msc)
                      (updN flist inum {| BFData := d; BFAttr := a; BFCache := None |})
                      ilist).
  Proof.
    intros.
    rewrite locked_eq in *.
    unfold cache_rep in *.
    eapply list2nmem_sel in H0 as H0'.
    case_eq (BFCache f); intros.
    - eapply pimpl_apply.
      2: eapply BFM.mm_remove.
      rewrite arrayN_isolate with (i := inum) by simplen.
      unfold cache_ptsto at 2; simpl.
      erewrite selN_map by simplen. rewrite selN_updN_eq by simplen. cancel.
      rewrite map_updN. rewrite firstn_updN_oob by omega.
      rewrite skipn_updN by omega.
      pred_apply.
      rewrite arrayN_isolate with (i := inum) by simplen.
      unfold cache_ptsto at 2.
      erewrite selN_map by simplen. rewrite <- H0'. rewrite H1. cancel.
      cancel.
    - eapply pimpl_apply.
      2: eapply BFM.mm_remove_none; eauto.
      rewrite arrayN_isolate with (i := inum) by simplen.
      rewrite arrayN_isolate with (i := inum) (vs := map _ _) by simplen.
      rewrite map_updN. rewrite firstn_updN_oob by omega.
      simpl; rewrite skipn_updN by omega.
      cancel.
      unfold cache_ptsto.
      erewrite selN_map by simplen. rewrite H1.
      rewrite selN_updN_eq by simplen.
      cancel.
      eapply cache_ptsto_none_find; eauto.
      simplen.
      erewrite selN_map by simplen.
      rewrite <- H0'; eauto.
  Unshelve.
    all: try exact None.
    all: eauto.
  Qed.

  Lemma bfcache_remove : forall msc flist ilist inum f F,
    locked (cache_rep msc flist ilist) ->
    (F * inum |-> f)%pred (list2nmem flist) ->
    BFData f = nil ->
    BFAttr f = attr0 ->
    locked (cache_rep (BFcache.remove inum msc) (updN flist inum bfile0) ilist).
  Proof.
    intros.
    eapply bfcache_remove' in H; eauto.
  Qed.

  Lemma rep_bfcache_remove : forall bxps sm ixp flist ilist frees allocc mscache icache dblocks inum f F,
    (F * inum |-> f)%pred (list2nmem flist) ->
    rep bxps sm ixp flist ilist frees allocc mscache icache dblocks =p=>
    rep bxps sm ixp (updN flist inum {| BFData := BFData f; BFAttr := BFAttr f; BFCache := None |}) ilist frees allocc
      (BFcache.remove inum mscache) icache dblocks.
  Proof.
    unfold rep; intros.
    norml. unfold stars; cbn.
    rewrite listmatch_length_pimpl.
    cancel.
    seprewrite.
    erewrite <- updN_selN_eq with (l := ilist) (ix := inum) at 2.
    rewrite listmatch_length_pimpl; cancel.
    eapply listmatch_updN_selN; try simplen.
    unfold file_match; cancel.
    eapply bfcache_remove'.
    eauto.
    sepauto.
  Unshelve.
    all: eauto using INODE.inode0.
  Qed.

  Hint Resolve bfcache_init bfcache_upd.

  Ltac assignms :=
    match goal with
    [ fms : memstate |- LOG.rep _ _ _ ?ms _ _ _ =p=> LOG.rep _ _ _ (MSLL ?e) _ _ _ ] =>
      is_evar e; eassign (mk_memstate (MSAlloc fms) ms (MSAllocC fms) (MSIAllocC fms) (MSICache fms) (MSCache fms) (MSDBlocks fms)); simpl; eauto
    end.

  (*** specification *)
  Local Hint Extern 1 (LOG.rep _ _ _ ?ms _ _ _ =p=> LOG.rep _ _ _ (MSLL ?e) _ _ _ ) => assignms.
  Local Opaque Nat.div.

  Theorem shuffle_allocs_ok :
    forall lxp bxps ms cms pr,
    {< F Fm Fs m0 sm m frees,
    PERM:pr   
    PRE:bm, hm,
           LOG.rep lxp F (LOG.ActiveTxn m0 m) ms sm bm hm *
           [[[ m ::: (Fm * BALLOCC.rep (fst bxps) (fst frees) (BALLOCC.mk_memstate ms (fst cms)) *
                           BALLOCC.rep (snd bxps) (snd frees) (BALLOCC.mk_memstate ms (snd cms))) ]]] *
           [[ (Fs * BALLOCC.smrep (fst frees) * BALLOCC.smrep (snd frees))%pred sm ]] *
           [[ forall bn, bn < (BmapNBlocks (fst bxps)) * valulen -> In bn (fst frees) ]] *
           [[ BmapNBlocks (fst bxps) = BmapNBlocks (snd bxps) ]]
    POST:bm', hm', RET:^(ms',cms')  exists m' frees',
           LOG.rep lxp F (LOG.ActiveTxn m0 m') ms' sm bm' hm' *
           [[[ m' ::: (Fm * BALLOCC.rep (fst bxps) (fst frees') (BALLOCC.mk_memstate ms' (fst cms')) *
                            BALLOCC.rep (snd bxps) (snd frees') (BALLOCC.mk_memstate ms' (snd cms'))) ]]] *
           [[ (Fs * BALLOCC.smrep (fst frees') * BALLOCC.smrep (snd frees'))%pred sm ]]
    CRASH:bm', hm',  LOG.intact lxp F m0 sm bm' hm'
    >} shuffle_allocs lxp bxps ms cms.
  Proof. 
    unfold shuffle_allocs.
    intros.
    eapply pimpl_ok2.
    monad_simpl.
    eapply forN_ok'.
    cancel.
    step.
    unfold BALLOCC.bn_valid; split; auto.
    denote (lt m1) as Hm.
    rewrite Nat.sub_add in Hm by omega.
    apply Rounding.lt_div_mul_lt in Hm; omega.
    denote In as Hb.
    eapply Hb.
    unfold BALLOCC.bn_valid; split; auto.
    denote (lt m1) as Hm.
    rewrite Nat.sub_add in Hm by omega.
    apply Rounding.lt_div_mul_lt in Hm; omega.
    step.
    unfold BALLOCC.bn_valid; split; auto.
    substl (BmapNBlocks bxps_2); auto.
    denote (lt m1) as Hm.
    rewrite Nat.sub_add in Hm by omega.
    apply Rounding.lt_div_mul_lt in Hm; omega.
    step.
    safestep.
    erewrite LOG.rep_hashmap_subset; eauto.
    pred_apply.
    subst; cancel.
    cancel.
    apply remove_other_In.
    omega.
    intuition.
    rewrite <- H1; cancel; eauto.
    rewrite <- H1; cancel; eauto.
    step.
    step.
    erewrite LOG.rep_hashmap_subset; eauto.
    eassign (false_pred(AT:=addr)(AEQ:=addr_eq_dec)(V:=valuset)).
    unfold false_pred; cancel.
    Unshelve. exact tt. all: eauto.
  Qed.

  Hint Extern 1 ({{_|_}} Bind (shuffle_allocs _ _ _ _) _) => apply shuffle_allocs_ok : prog.

  Local Hint Resolve INODE.IRec.Defs.items_per_val_gt_0 INODE.IRec.Defs.items_per_val_not_0 valulen_gt_0.

  Theorem init_ok :
    forall lxp bxps ibxp ixp ms pr,
    {< F Fm Fs m0 sm m l sl,
    PERM:pr
    PRE:bm, hm,
           LOG.rep lxp F (LOG.ActiveTxn m0 m) ms sm bm hm *
           [[[ m ::: (Fm * arrayN (@ptsto _ _ _) 0 l) ]]] *
           [[ (Fs * arrayN (@ptsto _ _ _) 0 sl)%pred sm ]] *
           [[ length sl = length l ]] *
           [[ let data_bitmaps := (BmapNBlocks (fst bxps)) in
              let inode_bitmaps := (IAlloc.Sig.BMPLen ibxp) in
              let data_blocks := (data_bitmaps * valulen)%nat in
              let inode_blocks := (inode_bitmaps * valulen / INODE.IRecSig.items_per_val)%nat in
              let inode_base := data_blocks in
              let balloc_base1 := inode_base + inode_blocks + inode_bitmaps in
              let balloc_base2 := balloc_base1 + data_bitmaps in
              length l = balloc_base2 + data_bitmaps /\
              BmapNBlocks (fst bxps) = BmapNBlocks (snd bxps) /\
              BmapStart (fst bxps) = balloc_base1 /\
              BmapStart (snd bxps) = balloc_base2 /\
              IAlloc.Sig.BMPStart ibxp = inode_base + inode_blocks /\
              IXStart ixp = inode_base /\ IXLen ixp = inode_blocks /\
              data_bitmaps <> 0 /\ inode_bitmaps <> 0 /\
              data_bitmaps <= valulen * valulen /\
             inode_bitmaps <= valulen * valulen
           ]]
    POST:bm', hm', RET:ms'  exists m' n frees freeinodes freeinode_pred,
           LOG.rep lxp F (LOG.ActiveTxn m0 m') (MSLL ms') sm bm' hm' *
           [[[ m' ::: (Fm * rep bxps sm ixp (repeat bfile0 n)
                                (repeat INODE.inode0 n) frees (MSAllocC ms')
                                (MSCache ms') (MSICache ms') (MSDBlocks ms') *
                       @IAlloc.rep bfile freepred ibxp freeinodes
                                   freeinode_pred (MSIAlloc ms')) ]]] *
           [[ n = ((IXLen ixp) * INODE.IRecSig.items_per_val)%nat /\ n > 1 ]] *
           [[ forall dl, length dl = n ->
                         Forall freepred dl ->
                         arrayN (@ptsto _ _ _) 0 dl =p=> freeinode_pred ]]
    CRASH:bm', hm',  LOG.intact lxp F m0 sm bm' hm'
    >} init lxp bxps ibxp ixp ms.
  Proof. 
    unfold init, rep, smrep.

    (* BALLOC.init_nofree *)
    prestep. norm. cancel.
    intuition simpl. pred_apply.

    (* now we need to split the LHS several times to get the correct layout *)
    erewrite arrayN_split at 1; repeat rewrite Nat.add_0_l.
    (* data alloc2 is the last chunk *)
    apply sep_star_assoc.
    eauto.
    omega. omega.
    rewrite skipn_length; omega.

    (* BALLOC.init *)
    prestep. norm. cancel.
    intuition simpl. pred_apply.
    erewrite arrayN_split at 1; repeat rewrite Nat.add_0_l.
    erewrite arrayN_split with (i := (BmapNBlocks bxps_1) * valulen) at 1; repeat rewrite Nat.add_0_l.
    (* data region is the first chunk, and data alloc1 is the last chunk *)
    eassign(BmapStart bxps_1); cancel.
    pred_apply.
    erewrite arrayN_split with (i := BmapStart bxps_2). repeat rewrite Nat.add_0_l.
    erewrite arrayN_split with (i := BmapStart bxps_1) (a := firstn _ _). repeat rewrite Nat.add_0_l.
    erewrite arrayN_split with (i := (BmapNBlocks bxps_1) * valulen) at 1; repeat rewrite Nat.add_0_l.
    rewrite arrayN_listpred_seq by eauto. rewrite Nat.add_0_r.
    repeat rewrite firstn_length.
    substl (length sl).
    cancel.
    omega.
    rewrite skipn_length.
    rewrite firstn_length_l; omega.
    repeat rewrite firstn_firstn.
    repeat rewrite Nat.min_l; try omega.
    rewrite firstn_length_l; omega.

    (* IAlloc.init *)
    prestep. norm. cancel.
    intuition simpl. pred_apply.
    erewrite arrayN_split at 1; repeat rewrite Nat.add_0_l.
    (* inode region is the first chunk, and inode alloc is the second chunk *)
    substl (IAlloc.Sig.BMPStart ibxp).
    eassign (IAlloc.Sig.BMPLen ibxp * valulen / INODE.IRecSig.items_per_val).
    cancel.

    denote (IAlloc.Sig.BMPStart) as Hx; contradict Hx.
    substl (IAlloc.Sig.BMPStart ibxp); intro.
    eapply add_nonzero_exfalso_helper2; eauto.
    rewrite skipn_skipn, firstn_firstn.
    rewrite Nat.min_l, skipn_length by omega.
    rewrite firstn_length_l by omega.
    omega.

    (* Inode.init *)
    prestep. norm. cancel.
    intuition simpl. pred_apply.
    substl (IXStart ixp); cancel.
    denote BALLOCC.smrep as Hs. exact Hs.

    rewrite firstn_firstn, firstn_length, skipn_length, firstn_length.
    repeat rewrite Nat.min_l with (n := (BmapStart bxps_1)) by omega.
    rewrite Nat.min_l; omega.
    denote (IXStart ixp) as Hx; contradict Hx.
    substl (IXStart ixp); intro.
    eapply add_nonzero_exfalso_helper2 with (b := 0).
    rewrite Nat.add_0_r; eauto.
    auto.

    (* shuffle_allocs *)
    step.
    step.

    (* post condition *)
    prestep; unfold IAlloc.rep; cancel.
    erewrite LOG.rep_hashmap_subset; eauto.
    pred_apply.
    cancel.
    apply file_match_init_ok.
    rewrite <- smrep_init. cancel.

    substl (IXLen ixp).
    apply Rounding.div_lt_mul_lt; auto.
    rewrite Nat.div_small.
    apply Nat.div_str_pos; split.
    apply INODE.IRec.Defs.items_per_val_gt_0.
    rewrite Nat.mul_comm.
    apply Rounding.div_le_mul; try omega.
    cbv; omega.
    unfold INODE.IRecSig.items_per_val.
    rewrite valulen_is.
    vm_compute; omega.

    denote (_ =p=> freepred0) as Hx; apply Hx.
    substl (length dl); substl (IXLen ixp).
    apply Rounding.mul_div; auto.
    apply Nat.mod_divide; auto.
    apply Nat.divide_mul_r.
    unfold INODE.IRecSig.items_per_val.
    apply Nat.mod_divide; auto.
    rewrite valulen_is.
    vm_compute; auto.
    auto.
    auto.
    
    all: rewrite <- H1; cancel; eauto.
    Unshelve. all: eauto.
  Qed.

  Theorem getlen_ok :
    forall lxp bxps ixp inum ms pr,
    {< F Fm Fi m0 sm m f flist ilist allocc frees,
    PERM:pr   
    PRE:bm, hm,
           LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms) sm bm hm *
           [[[ m ::: (Fm * rep bxps sm ixp flist ilist frees allocc (MSCache ms) (MSICache ms) (MSDBlocks ms)) ]]] *
           [[[ flist ::: (Fi * inum |-> f) ]]]
    POST:bm', hm', RET:^(ms',r)
           LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms') sm bm' hm' *
           [[[ m ::: (Fm * rep bxps sm ixp flist ilist frees allocc (MSCache ms') (MSICache ms') (MSDBlocks ms')) ]]] *
           [[ r = length (BFData f) ]] *
           [[ MSAlloc ms = MSAlloc ms' ]] *
           [[ MSCache ms = MSCache ms' ]] *
           [[ MSIAllocC ms = MSIAllocC ms' ]] *
           [[ MSAllocC ms = MSAllocC ms' ]] *
           [[ MSDBlocks ms = MSDBlocks ms' ]]
    CRASH:bm', hm',  exists ms',
           LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms') sm bm' hm'
    >} getlen lxp ixp inum ms.
  Proof. 
    unfold getlen, rep.
    safestep.
    sepauto.

    safestep.
    safestep.
    erewrite LOG.rep_hashmap_subset; eauto.
    extract; seprewrite; subst.
    denote (_ (list2nmem m)) as Hx.
    setoid_rewrite listmatch_length_pimpl in Hx at 2.
    destruct_lift Hx; eauto.
    simplen.

    cancel.
    rewrite <- H1; cancel; eauto.
    Unshelve. all: eauto.
  Qed.

  Theorem getattrs_ok :
    forall lxp bxp ixp inum ms pr,
    {< F Fm Fi m0 sm m flist ilist allocc frees f,
    PERM:pr   
    PRE:bm, hm,
           LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms) sm bm hm *
           [[[ m ::: (Fm * rep bxp sm ixp flist ilist frees allocc (MSCache ms) (MSICache ms) (MSDBlocks ms)) ]]] *
           [[[ flist ::: (Fi * inum |-> f) ]]]
    POST:bm', hm', RET:^(ms',r)
           LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms') sm bm' hm' *
           [[[ m ::: (Fm * rep bxp sm ixp flist ilist frees allocc (MSCache ms') (MSICache ms') (MSDBlocks ms')) ]]] *
           [[ r = BFAttr f ]] *
           [[ MSAllocC ms = MSAllocC ms' ]] *
           [[ MSAlloc ms = MSAlloc ms' ]] *
           [[ MSIAllocC ms = MSIAllocC ms' ]] *
           [[ MSCache ms = MSCache ms' ]] *
           [[ MSDBlocks ms = MSDBlocks ms' ]]
    CRASH:bm', hm',  exists ms',
           LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms') sm bm' hm'
    >} getattrs lxp ixp inum ms.
  Proof. 
    unfold getattrs, rep.
    safestep.
    sepauto.

    safestep.
    safestep.
    erewrite LOG.rep_hashmap_subset; eauto.
    extract; seprewrite.
    rewrite H22; eauto.

    cancel.
    rewrite <- H1; cancel; eauto.
  Qed.

  
  Definition treeseq_ilist_safe inum ilist1 ilist2 :=
    (forall off bn,
        block_belong_to_file ilist1 bn inum off ->
        block_belong_to_file ilist2 bn inum off) /\
    (forall i def,
        inum <> i -> selN ilist1 i def = selN ilist2 i def).

  Lemma treeseq_ilist_safe_refl : forall inum ilist,
    treeseq_ilist_safe inum ilist ilist.
  Proof.
    unfold treeseq_ilist_safe; intuition.
  Qed.

  Lemma treeseq_ilist_safe_trans : forall inum ilist0 ilist1 ilist2,
    treeseq_ilist_safe inum ilist0 ilist1 ->
    treeseq_ilist_safe inum ilist1 ilist2 ->
    treeseq_ilist_safe inum ilist0 ilist2.
  Proof.
    unfold treeseq_ilist_safe; intuition.
    erewrite H2 by eauto.
    erewrite H3 by eauto.
    eauto.
  Qed.

  Theorem setattrs_ok :
    forall lxp bxps ixp inum a ms pr,
    {< F Fm Ff m0 sm m flist ilist allocc frees f,
    PERM:pr
    PRE:bm, hm,
           LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms) sm bm hm *
           [[[ m ::: (Fm * rep bxps sm ixp flist ilist frees allocc (MSCache ms) (MSICache ms) (MSDBlocks ms)) ]]] *
           [[[ flist ::: (Ff * inum |-> f) ]]] 
    POST:bm', hm', RET:ms'  exists m' flist' f' ilist',
           LOG.rep lxp F (LOG.ActiveTxn m0 m') (MSLL ms') sm bm' hm' *
           [[[ m' ::: (Fm * rep bxps sm ixp flist' ilist' frees allocc (MSCache ms') (MSICache ms') (MSDBlocks ms')) ]]] *
           [[[ flist' ::: (Ff * inum |-> f') ]]] *
           [[ f' = mk_bfile (BFData f) a (BFCache f) ]] *
           [[ MSAllocC ms = MSAllocC ms' ]] *
           [[ MSIAllocC ms = MSIAllocC ms' ]] *
           [[ MSDBlocks ms = MSDBlocks ms' ]] *
           [[ MSAlloc ms = MSAlloc ms' /\
              let free := pick_balloc frees (MSAlloc ms') in
              ilist_safe ilist free ilist' free ]] *
           [[ treeseq_ilist_safe inum ilist ilist' ]]
    CRASH:bm', hm',  LOG.intact lxp F m0 sm bm' hm'
    >} setattrs lxp ixp inum a ms.
  Proof. 
    unfold setattrs, rep.
    safestep.
    sepauto.
    safestep.
    safestep.
    erewrite LOG.rep_hashmap_subset; eauto.
    pred_apply; safecancel.
    repeat extract. seprewrite.
    4: sepauto.
    4: eauto.
    eapply listmatch_updN_selN; try omega.
    unfold file_match; cancel.
    seprewrite.
    eapply bfcache_upd; cbn; simplen.
    eauto.
    repeat extract. seprewrite.
    rewrite length_updN in *.
    unfold smrep.
    rewrite arrayN_except with (i:= inum); simpl; auto.
    rewrite arrayN_except_upd with (i:= inum); simpl; auto.
    eassign dummy1; cancel.
    unfold smrep_single_helper, smrep_single; simpl; cancel.
    denote (list2nmem m') as Hm'.
    rewrite listmatch_length_pimpl in Hm'; destruct_lift Hm'.
    denote (list2nmem ilist') as Hilist'.
    assert (inum < length ilist) by simplen'.
    apply arrayN_except_upd in Hilist'; eauto.
    apply list2nmem_array_eq in Hilist'; subst.
    unfold ilist_safe; intuition. left.
    destruct (addr_eq_dec inum inum0); subst.
    - unfold block_belong_to_file in *; intuition.
      all: erewrite selN_updN_eq in * by eauto; simpl; eauto.
    - unfold block_belong_to_file in *; intuition.
      all: erewrite selN_updN_ne in * by eauto; simpl; eauto.
    - unfold treeseq_ilist_safe.
      split.
      intros.
      seprewrite.
      unfold block_belong_to_file in *.
      intuition simplen.

      intuition.
      assert (inum < length ilist) by simplen'.
      denote arrayN_ex as Ha.
      apply arrayN_except_upd in Ha; auto.
      apply list2nmem_array_eq in Ha; subst.
      rewrite selN_updN_ne; auto.
    - cancel.
  Qed.

  Theorem updattr_ok :
    forall lxp bxps ixp inum kv ms pr,
    {< F Fm Fi m0 sm m flist ilist frees allocc f,
    PERM:pr   
    PRE:bm, hm,
           LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms) sm bm hm *
           [[[ m ::: (Fm * rep bxps sm ixp flist ilist frees allocc (MSCache ms) (MSICache ms) (MSDBlocks ms)) ]]] *
           [[[ flist ::: (Fi * inum |-> f) ]]]
    POST:bm', hm', RET:ms'  exists m' flist' ilist' f',
           LOG.rep lxp F (LOG.ActiveTxn m0 m') (MSLL ms') sm bm' hm' *
           [[[ m' ::: (Fm * rep bxps sm ixp flist' ilist' frees allocc (MSCache ms') (MSICache ms') (MSDBlocks ms')) ]]] *
           [[[ flist' ::: (Fi * inum |-> f') ]]] *
           [[ f' = mk_bfile (BFData f) (INODE.iattr_upd (BFAttr f) kv) (BFCache f) ]] *
           [[ MSDBlocks ms = MSDBlocks ms' ]] *
           [[ MSIAllocC ms = MSIAllocC ms' ]] *
           [[ MSAlloc ms = MSAlloc ms' /\
              let free := pick_balloc frees (MSAlloc ms') in
              ilist_safe ilist free ilist' free ]]
    CRASH:bm', hm',  LOG.intact lxp F m0 sm bm' hm'
    >} updattr lxp ixp inum kv ms.
  Proof. 
    unfold updattr, rep.
    step.
    sepauto.

    safestep.
    safestep.
    erewrite LOG.rep_hashmap_subset; eauto.
    pred_apply; safecancel.
    repeat extract. seprewrite.
    4: sepauto.
    4: eauto.
    eapply listmatch_updN_selN; try omega.
    unfold file_match; cancel.
    seprewrite.
    eapply bfcache_upd; cbn; simplen.
    eauto.
    repeat extract. seprewrite.
    rewrite length_updN in *.
    unfold smrep.
    rewrite arrayN_except with (i:= inum); simpl; auto.
    rewrite arrayN_except_upd with (i:= inum); simpl; auto.
    eassign dummy1; cancel.
    unfold smrep_single_helper, smrep_single; simpl; cancel.

    denote (list2nmem m') as Hm'.
    rewrite listmatch_length_pimpl in Hm'; destruct_lift Hm'.
    denote (list2nmem ilist') as Hilist'.
    assert (inum < length ilist) by simplen'.
    apply arrayN_except_upd in Hilist'; eauto.
    apply list2nmem_array_eq in Hilist'; subst.
    unfold ilist_safe; intuition. left.
    destruct (addr_eq_dec inum inum0); subst.
    - unfold block_belong_to_file in *; intuition.
      all: erewrite selN_updN_eq in * by eauto; simpl; eauto.
    - unfold block_belong_to_file in *; intuition.
      all: erewrite selN_updN_ne in * by eauto; simpl; eauto.
    - cancel.
  Qed.

  Theorem read_ok :
    forall lxp bxp ixp inum off ms pr,
    {< F Fm Fi Fd m0 sm m flist ilist frees allocc f vs,
    PERM:pr   
    PRE:bm, hm,
           LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms) sm bm hm *
           [[ off < length (BFData f) ]] *
           [[[ m ::: (Fm * rep bxp sm ixp flist ilist
               frees allocc (MSCache ms) (MSICache ms) (MSDBlocks ms)) ]]] *
           [[[ flist ::: (Fi * inum |-> f) ]]] *
           [[[ (BFData f) ::: (Fd * off |-> vs) ]]]
    POST:bm', hm', RET:^(ms', r)
           LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms') sm bm' hm' *
           [[[ m ::: (Fm * rep bxp sm ixp flist ilist frees allocc (MSCache ms') (MSICache ms') (MSDBlocks ms')) ]]] *
           [[ MSIAllocC ms = MSIAllocC ms' ]] *
           [[ bm' r = Some (fst vs) /\ MSAlloc ms = MSAlloc ms' /\ MSCache ms = MSCache ms' /\ MSDBlocks ms = MSDBlocks ms' /\
              MSAllocC ms = MSAllocC ms' ]]
    CRASH:bm', hm',  exists ms',
           LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms') sm bm' hm'
    >} read lxp ixp inum off ms.
  Proof. 
    unfold read, rep.
    prestep; norml.
    extract; seprewrite; subst.
    denote (_ (list2nmem m)) as Hx.
    setoid_rewrite listmatch_length_pimpl in Hx at 2.
    rewrite map_length in *.
    destruct_lift Hx.
    safecancel.
    eauto.

    sepauto.
    denote (_ (list2nmem m)) as Hx.
    setoid_rewrite listmatch_extract with (i := off) in Hx at 2; try omega.
    destruct_lift Hx; filldef.
    safestep.
    rewrite listmatch_extract with (i := off) (b := map _ _) by omega.
    erewrite selN_map by omega; filldef.
    (*rewrite <- surjective_pairing. *)
    cancel.
    step.
    step.
    erewrite LOG.rep_hashmap_subset; eauto.
    rewrite listmatch_isolate with (a := flist) (i := inum) by omega.
    unfold file_match. cancel.
    all: rewrite <- H1; cancel; eauto.
    Unshelve. all: eauto.
  Qed.


  Theorem write_ok :
    forall lxp bxp ixp inum off h ms pr,
    {< F Fm Fi Fd m0 sm m flist ilist frees allocc f v vs0,
    PERM:pr   
    PRE:bm, hm,
           LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms) sm bm hm *
           [[ off < length (BFData f) ]] *
           [[[ m ::: (Fm * rep bxp sm ixp flist ilist frees allocc (MSCache ms) (MSICache ms) (MSDBlocks ms)) ]]] *
           [[[ flist ::: (Fi * inum |-> f) ]]] *
           [[[ (BFData f) ::: (Fd * off |-> vs0) ]]] *
           [[ bm h = Some v ]]
    POST:bm', hm', RET:ms'  exists m' flist' f',
           LOG.rep lxp F (LOG.ActiveTxn m0 m') (MSLL ms') sm bm' hm' *
           [[[ m' ::: (Fm * rep bxp sm ixp flist' ilist frees allocc (MSCache ms') (MSICache ms') (MSDBlocks ms')) ]]] *
           [[[ flist' ::: (Fi * inum |-> f') ]]] *
           [[[ (BFData f') ::: (Fd * off |-> (v, nil)) ]]] *
           [[ f' = mk_bfile (updN (BFData f) off (v, nil)) (BFAttr f) (BFCache f) ]] *
           [[ MSAlloc ms = MSAlloc ms' ]] *
           [[ MSCache ms = MSCache ms' ]] *
           [[ MSIAllocC ms = MSIAllocC ms' ]] *
           [[ MSAllocC ms = MSAllocC ms' ]]
    CRASH:bm', hm',  LOG.intact lxp F m0 sm bm' hm'
    >} write lxp ixp inum off h ms.
  Proof. 
    unfold write, rep.
    prestep; norml.
    extract; seprewrite; subst.
    denote (_ (list2nmem m)) as Hx.
    setoid_rewrite listmatch_length_pimpl in Hx at 2.
    rewrite map_length in *.
    destruct_lift Hx; safecancel.
    eauto.
    sepauto.

    denote (_ (list2nmem m)) as Hx.
    setoid_rewrite listmatch_extract with (i := off) in Hx at 2; try omega.
    destruct_lift Hx; filldef.
    step.

    setoid_rewrite INODE.inode_rep_bn_nonzero_pimpl in H.
    destruct_lift H; denote (_ <> 0) as Hx; subst.
    eapply Hx; try eassumption; omega.
    rewrite listmatch_extract with (b := map _ _) (i := off) by omega.
    erewrite selN_map by omega; filldef.
    (* rewrite <- surjective_pairing. *)
    cancel.
    step.
    prestep. norm. cancel.
    erewrite LOG.rep_hashmap_subset; eauto.
    intuition cbn.
    2: sepauto.
    2: cbn; sepauto.
    pred_apply. cancel.
    rewrite listmatch_isolate with (a := updN _ _ _) by simplen.
    rewrite removeN_updN, selN_updN_eq by simplen.
    unfold file_match.
    cancel; eauto.
    rewrite listmatch_isolate with (a := updN _ _ _) by simplen.
    rewrite removeN_updN, selN_updN_eq by simplen.
    erewrite selN_map by simplen.
    cancel.

    eauto.
    eauto.
    eauto.

    all: rewrite <- H1; cancel; eauto.
  Grab Existential Variables.
    all: try exact unit.
    all: intros; eauto.
    all: try solve [exact bfile0 | exact INODE.inode0].
    all: try split; auto using nil, tt.
  Qed.


  Lemma grow_treeseq_ilist_safe: forall (ilist: list INODE.inode) ilist' inum a,
    inum < Datatypes.length ilist ->
    (arrayN_ex (ptsto (V:=INODE.inode)) ilist inum
     ✶ inum
       |-> {|
           INODE.IBlocks := INODE.IBlocks (selN ilist inum INODE.inode0) ++ [$ (a)];
           INODE.IAttr := INODE.IAttr (selN ilist inum INODE.inode0);
           INODE.IOwner := INODE.IOwner (selN ilist inum INODE.inode0) |})%pred (list2nmem ilist') ->
    treeseq_ilist_safe inum ilist ilist'.
  Proof.
    intros.
    unfold treeseq_ilist_safe, block_belong_to_file.
    apply arrayN_except_upd in H0 as Hselupd; auto.
    apply list2nmem_array_eq in Hselupd; subst.
    split. 
    intros.
    split.
    erewrite selN_updN_eq; simpl.
    erewrite app_length.
    omega.
    simplen'.
    intuition.
    erewrite selN_updN_eq; simpl.
    erewrite selN_app; eauto.
    simplen'.
    intros.
    erewrite selN_updN_ne; eauto.
  Qed.


  Theorem grow_ok : 
    forall lxp bxp ixp inum h ms pr,
    {< F Fm Fi Fd m0 sm m flist ilist frees v f,
    PERM:pr
    PRE:bm, hm,
           LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms) sm bm hm *
           [[[ m ::: (Fm * rep bxp sm ixp flist ilist frees (MSAllocC ms) (MSCache ms) (MSICache ms) (MSDBlocks ms)) ]]] *
           [[[ flist ::: (Fi * inum |-> f) ]]] *
           [[[ (BFData f) ::: Fd ]]] *
           [[ bm h = Some v ]]
    POST:bm', hm', RET:^(ms', r) 
           [[ MSAlloc ms = MSAlloc ms' /\ MSCache ms = MSCache ms' ]] *
           [[ MSIAllocC ms = MSIAllocC ms' ]] * exists m',
           [[ isError r ]] * LOG.rep lxp F (LOG.ActiveTxn m0 m') (MSLL ms') sm bm' hm' \/
           [[ r = OK tt  ]] * exists flist' ilist' frees' f',
           LOG.rep lxp F (LOG.ActiveTxn m0 m') (MSLL ms') sm bm' hm' *
           [[[ m' ::: (Fm * rep bxp sm ixp flist' ilist' frees' (MSAllocC ms') (MSCache ms') (MSICache ms') (MSDBlocks ms')) ]]] *
           [[[ flist' ::: (Fi * inum |-> f') ]]] *
           [[[ (BFData f') ::: (Fd * (length (BFData f)) |-> (v, nil)) ]]] *
           [[ f' = mk_bfile ((BFData f) ++ [(v, nil)]) (BFAttr f) (BFCache f) ]] *
           [[ ilist_safe ilist  (pick_balloc frees  (MSAlloc ms'))
                         ilist' (pick_balloc frees' (MSAlloc ms')) ]] *
           [[ treeseq_ilist_safe inum ilist ilist' ]]
    CRASH:bm', hm',  LOG.intact lxp F m0 sm bm' hm'
    >} grow lxp bxp ixp inum h ms.
  Proof. 
    unfold grow.
    prestep; norml; unfold stars; simpl.
    denote rep as Hr.
    rewrite rep_alt_equiv with (msalloc := MSAlloc ms) in Hr.
    unfold rep_alt, smrep in Hr; destruct_lift Hr.
    extract. seprewrite; subst.
    denote removeN as Hx.
    setoid_rewrite listmatch_length_pimpl in Hx at 2.
    rewrite map_length in *.
    destruct_lift Hx. safecancel.
    sepauto.

    step.

    (* file size ok, do allocation *)
    {
      step.
      safestep.
      sepauto.
      step.

      eapply BALLOCC.bn_valid_facts; eauto.
      step.
      step.
      
      or_r; safecancel.
      erewrite LOG.rep_hashmap_subset; eauto.
      pred_apply.
      rewrite rep_alt_equiv with (msalloc := MSAlloc ms); unfold rep_alt.
      erewrite pick_upd_balloc_lift with (new := freelist') (flag := MSAlloc ms) (p := (frees_1, frees_2)) at 1.
      rewrite pick_negb_upd_balloc with (new := freelist') (flag := MSAlloc ms) at 1.
      unfold upd_balloc.

      match goal with a : BALLOCC.Alloc.memstate |- _ =>
        progress replace a with (BALLOCC.mk_memstate (BALLOCC.MSLog a) (BALLOCC.MSCache a)) at 1 by (destruct a; reflexivity);
        setoid_rewrite pick_upd_balloc_lift with (new := (BALLOCC.MSCache a) ) (flag := MSAlloc ms) at 1;
        rewrite pick_negb_upd_balloc with (new := (BALLOCC.MSCache a)) (flag := MSAlloc ms) at 1
      end.
      unfold upd_balloc.

      cancel.

      4: sepauto.
      5: eauto.
      seprewrite.
      rewrite listmatch_updN_removeN by simplen.
      unfold file_match; cancel.
      rewrite map_app; simpl.
      rewrite <- listmatch_app_tail.
      cancel.

      rewrite map_length; omega.
      rewrite wordToNat_natToWord_idempotent'; auto.
      eapply BALLOCC.bn_valid_goodSize; eauto.
      seprewrite.
      eapply bfcache_upd; eauto.
      eauto.
      rewrite <- smrep_upd_add; eauto.
      cancel.
      unfold smrep. destruct MSAlloc; cancel.
      eauto.
      eapply BALLOCC.bn_valid_goodSize; eauto.
      sepauto.
      cbn; auto.
      apply list2nmem_app; eauto.

      2: eauto using grow_treeseq_ilist_safe.

      2: cancel.
      (* 2: or_l; cancel. *)

      denote (list2nmem ilist') as Hilist'.
      assert (inum < length ilist) by simplen'.
      apply arrayN_except_upd in Hilist'; eauto.
      apply list2nmem_array_eq in Hilist'; subst.
      unfold ilist_safe; intuition.

      destruct (MSAlloc ms); simpl in *; eapply incl_tran; eauto; eapply incl_remove.

      destruct (addr_eq_dec inum inum0); subst.
      + unfold block_belong_to_file in *; intuition.
        all: erewrite selN_updN_eq in * by eauto; simpl in *; eauto.
        destruct (addr_eq_dec off (length (INODE.IBlocks (selN ilist inum0 INODE.inode0)))).
        * right.
          rewrite selN_last in * by auto.
          subst. rewrite wordToNat_natToWord_idempotent'. eauto.
          eapply BALLOCC.bn_valid_goodSize; eauto.
        * left.
          rewrite app_length in *; simpl in *.
          split. omega.
          subst. rewrite selN_app1 by omega. auto.
      + unfold block_belong_to_file in *; intuition.
        all: erewrite selN_updN_ne in * by eauto; simpl; eauto.
      + rewrite <- H1; cancel; eauto.
      + step.
        or_l; cancel.
        erewrite LOG.rep_hashmap_subset; eauto.
      + rewrite <- H1; cancel; eauto.
      + step.
        or_l; cancel.
        erewrite LOG.rep_hashmap_subset; eauto.
      + cancel.
      + rewrite <- H1; cancel; eauto.
    }

    step.
    step.
    or_l; cancel; eauto.
    erewrite LOG.rep_hashmap_subset; eauto.
    rewrite <- H1; cancel; eauto.
    Unshelve. all: easy.
  Qed.

  Local Hint Extern 0 (okToUnify (listmatch _ _ ?a) (listmatch _ _ ?a)) => constructor : okToUnify.
  Local Hint Extern 0 (okToUnify (listmatch _ ?a _) (listmatch _ ?a _)) => constructor : okToUnify.
  Local Hint Extern 0 (okToUnify (listmatch _ _ (?f _ _)) (listmatch _ _ (?f _ _))) => constructor : okToUnify.
  Local Hint Extern 0 (okToUnify (listmatch _ (?f _ _) _) (listmatch _ (?f _ _) _)) => constructor : okToUnify.

  Theorem shrink_ok :
    forall lxp bxp ixp inum nr ms pr,
    {< F Fm Fi m0 sm m flist ilist frees f,
    PERM:pr   
    PRE:bm, hm,
           LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms) sm bm hm *
           [[[ m ::: (Fm * rep bxp sm ixp flist ilist frees (MSAllocC ms) (MSCache ms) (MSICache ms) (MSDBlocks ms)) ]]] *
           [[[ flist ::: (Fi * inum |-> f) ]]]
    POST:bm', hm', RET:ms'  exists m' flist' f' ilist' frees',
           LOG.rep lxp F (LOG.ActiveTxn m0 m') (MSLL ms') sm bm' hm' *
           [[[ m' ::: (Fm * rep bxp sm ixp flist' ilist' frees' (MSAllocC ms') (MSCache ms') (MSICache ms') (MSDBlocks ms')) ]]] *
           [[[ flist' ::: (Fi * inum |-> f') ]]] *
           [[ f' = mk_bfile (firstn ((length (BFData f)) - nr) (BFData f)) (BFAttr f) (BFCache f) ]] *
           [[ MSCache ms = MSCache ms' ]] *
           [[ MSIAllocC ms = MSIAllocC ms' ]] *
           [[ MSAlloc ms = MSAlloc ms' /\
              ilist_safe ilist  (pick_balloc frees  (MSAlloc ms'))
                         ilist' (pick_balloc frees' (MSAlloc ms')) ]] *
           [[ forall inum' def', inum' <> inum -> 
                selN ilist inum' def' = selN ilist' inum' def' ]]
    CRASH:bm', hm',  LOG.intact lxp F m0 sm bm' hm'
    >} shrink lxp bxp ixp inum nr ms.
  Proof. 
    unfold shrink.
    prestep; norml; unfold stars; simpl.
    denote rep as Hr.
    rewrite rep_alt_equiv with (msalloc := MSAlloc ms) in Hr.
    unfold rep_alt in Hr; destruct_lift Hr.
    (* rewrite smrep_equiv with (b := MSAlloc ms) in *. *)
    unfold smrep in *.
    cancel.
    sepauto.
    extract; seprewrite; subst; denote removeN as Hx.
    setoid_rewrite listmatch_length_pimpl in Hx at 2.
    rewrite map_length in *.

    {
      step.
      erewrite INODE.rep_bxp_switch in Hx by eassumption.
      rewrite INODE.inode_rep_bn_valid_piff in Hx; destruct_lift Hx.
      denote Forall as Hv; specialize (Hv inum); subst.
      rewrite <- Forall_map.
      apply forall_skipn; apply Hv; eauto.
      
      erewrite <- listmatch_ptsto_listpred.
      rewrite listmatch_extract with (i := inum) (a := flist) by omega.
      unfold file_match at 2.
      setoid_rewrite listmatch_split at 2.
      rewrite skipn_map_comm; cancel.

      admit.
      
      destruct_lift Hx; denote (length (BFData _)) as Heq.
      (* rewrite arrayN_except with (i := inum) by omega.      
      unfold smrep_single_helper at 2. *)

      prestep.
      norm.
      cancel.
      intuition.

      pred_apply.
      erewrite INODE.rep_bxp_switch by eassumption. cancel.
      sepauto.
      sepauto.

      step.
      denote listmatch as Hx.
      setoid_rewrite listmatch_length_pimpl in Hx at 2.
      prestep; norm. cancel.
      erewrite LOG.rep_hashmap_subset; eauto.
      eassign (ilist'). intuition simpl.
      2: sepauto.

      rewrite rep_alt_equiv with (msalloc := MSAlloc ms); unfold rep_alt.
      pred_apply.
      erewrite pick_upd_balloc_lift with (new := freelist') (flag := negb (MSAlloc ms)) (p := (frees_1, frees_2)) at 1.
      rewrite pick_upd_balloc_negb with (new := freelist') (flag := MSAlloc ms) at 1.
      unfold upd_balloc.

      match goal with a : BALLOCC.Alloc.memstate |- _ =>
        progress replace a with (BALLOCC.mk_memstate (BALLOCC.MSLog a) (BALLOCC.MSCache a)) at 1 by (destruct a; reflexivity);
        setoid_rewrite pick_upd_balloc_lift with (new := (BALLOCC.MSCache a) ) (flag := negb (MSAlloc ms)) at 1;
        rewrite pick_upd_balloc_negb with (new := (BALLOCC.MSCache a)) (flag := MSAlloc ms) at 1
      end.
      unfold upd_balloc.

      erewrite INODE.rep_bxp_switch by ( apply eq_sym; eassumption ).
      cancel.

      seprewrite.
      rewrite listmatch_updN_removeN by omega.
      rewrite Heq.
      unfold file_match, cuttail; cancel; eauto.
      seprewrite.
      unfold cuttail.
      rewrite firstn_map_comm.
      (*eapply dirty_blocks_rep_firstn; cbn; eauto.*)
      congruence.
      eapply bfcache_upd; eauto.
      unfold smrep; simpl.
      denote (list2nmem ilist') as Hilist'.
      assert (inum < length ilist) by simplen.
      apply arrayN_except_upd in Hilist'; eauto.
      apply list2nmem_array_eq in Hilist'; subst.
      unfold ilist_safe; intuition.
      eassign ( arrayN
         (smrep_single_helper
            (remove_dirty inum
               (map (wordToNat (sz:=addrlen))
                  (skipn (length (INODE.IBlocks (selN ilist inum INODE.inode0)) - nr)
                     (INODE.IBlocks (selN ilist inum INODE.inode0)))) (MSDBlocks ms))) 0
         ilist ⟦ inum
         := {|
            INODE.IBlocks := cuttail nr (INODE.IBlocks (selN ilist inum INODE.inode0));
            INODE.IAttr := INODE.IAttr (selN ilist inum INODE.inode0);
            INODE.IOwner := INODE.IOwner (selN ilist inum INODE.inode0) |} ⟧ *
                if (MSAlloc ms) then BALLOCC.smrep frees_1 else BALLOCC.smrep frees_2)%pred.
      destruct (MSAlloc ms); simpl in *; cancel.
      
      denote (list2nmem ilist') as Hilist'.
      assert (inum < length ilist) by simplen.
      apply arrayN_except_upd in Hilist'; eauto.
      apply list2nmem_array_eq in Hilist'; subst.
      unfold ilist_safe; intuition.
      destruct (MSAlloc ms); simpl in *; eapply incl_refl.
      left.
      destruct (addr_eq_dec inum inum0); subst.
      all: eauto; try solve [rewrite <- H1; cancel; eauto].
      + unfold block_belong_to_file in *; intuition simpl.
        all: erewrite selN_updN_eq in * by eauto; simpl in *; eauto.
        rewrite cuttail_length in *. omega.
        rewrite selN_cuttail in *; auto.
      + unfold block_belong_to_file in *; intuition simpl.
        all: erewrite selN_updN_ne in * by eauto; simpl; eauto.
      + denote (arrayN_ex _ _ _) as Ha.
        eapply list2nmem_array_updN in Ha; eauto.
        rewrite Ha.
        erewrite selN_updN_ne; eauto.
    }

    rewrite <- H1; cancel; eauto.

  Unshelve.
    all : try easy.
    all : solve [ exact bfile0 | intros; exact emp | exact nil].
  Admitted.

  Theorem sync_ok :
    forall lxp ixp ms pr,
    {< F sm ds,
    PERM:pr   
    PRE:bm, hm,
      LOG.rep lxp F (LOG.NoTxn ds) (MSLL ms) sm bm hm *
      [[ sync_invariant F ]]
    POST:bm', hm', RET:ms'
      LOG.rep lxp F (LOG.NoTxn (ds!!, nil)) (MSLL ms') sm bm' hm' *
      [[ MSAlloc ms' = negb (MSAlloc ms) ]] *
      [[ MSCache ms' = MSCache ms ]] *
      [[ MSIAllocC ms = MSIAllocC ms' ]] *
      [[ MSICache ms = MSICache ms' ]] *
      [[ MSAllocC ms' = MSAllocC ms]]
    XCRASH:bm', hm',
      LOG.recover_any lxp F ds sm bm' hm'
    >} sync lxp ixp ms.
  Proof. 
    unfold sync, rep.
    step.
    step.
    step.
    erewrite LOG.rep_hashmap_subset; eauto.
  Qed.

  Theorem sync_noop_ok :
    forall lxp ixp ms pr,
    {< F sm ds,
    PERM:pr   
    PRE:bm, hm,
      LOG.rep lxp F (LOG.NoTxn ds) (MSLL ms) sm bm hm *
      [[ sync_invariant F ]]
    POST:bm', hm', RET:ms'
      LOG.rep lxp F (LOG.NoTxn ds) (MSLL ms') sm bm' hm' *
      [[ MSAlloc ms' = negb (MSAlloc ms) ]] *
      [[ MSCache ms' = MSCache ms ]] *
      [[ MSIAllocC ms = MSIAllocC ms' ]] *
      [[ MSICache ms = MSICache ms' ]] *
      [[ MSAllocC ms' = MSAllocC ms]]
    XCRASH:bm', hm',
      LOG.recover_any lxp F ds sm bm' hm'
    >} sync_noop lxp ixp ms.
  Proof.
    unfold sync_noop, rep.
    step.
    step.
    step.
    erewrite LOG.rep_hashmap_subset; eauto.
  Qed.

  Lemma block_belong_to_file_off_ok : forall Fm Fi sm bxp ixp flist ilist frees cms mscache icache dblocks inum off f m,
    (Fm * rep bxp sm ixp flist ilist frees cms mscache icache dblocks)%pred m ->
    (Fi * inum |-> f)%pred (list2nmem flist) ->
    off < Datatypes.length (BFData f) -> 
    block_belong_to_file ilist # (selN (INODE.IBlocks (selN ilist inum INODE.inode0)) off $0) inum off.
  Proof.
    unfold block_belong_to_file; intros; split; auto.
    unfold rep, INODE.rep in H; destruct_lift H.
    rewrite listmatch_extract with (i := inum) in H.
    unfold file_match in H; destruct_lift H.
    setoid_rewrite listmatch_extract with (i := inum) (b := ilist) in H.
    destruct_lift H.
    erewrite listmatch_length_pimpl with (a := BFData _) in H.
    destruct_lift H.
    rewrite map_length in *.
    simplen.
    simplen.
    rewrite combine_length_eq by omega.
    erewrite listmatch_length_pimpl with (b := ilist) in *.
    destruct_lift H. simplen.
    Unshelve. split; eauto. exact INODE.inode0.
  Qed.

  Lemma block_belong_to_file_ok : forall Fm Fi Fd bxp sm ixp flist ilist frees cms mscache icache dblocks inum off f vs m,
    (Fm * rep bxp sm ixp flist ilist frees cms mscache icache dblocks)%pred m ->
    (Fi * inum |-> f)%pred (list2nmem flist) ->
    (Fd * off |-> vs)%pred (list2nmem (BFData f)) ->
    block_belong_to_file ilist # (selN (INODE.IBlocks (selN ilist inum INODE.inode0)) off $0) inum off.
  Proof.
    intros.
    eapply list2nmem_inbound in H1.
    eapply block_belong_to_file_off_ok; eauto.
  Qed.

  Definition diskset_was (ds0 ds : diskset) := ds0 = ds \/ ds0 = (ds!!, nil).

  Theorem d_in_diskset_was : forall d ds ds',
    d_in d ds ->
    diskset_was ds ds' ->
    d_in d ds'.
  Proof.
    intros.
    inversion H0; subst; eauto.
    inversion H; simpl in *; intuition; subst.
    apply latest_in_ds.
  Qed.

  Theorem dwrite_ok :
    forall lxp bxp ixp inum off h ms pr,
    {< F Fm Fi Fd sm ds flist ilist frees allocc f v vs,
    PERM:pr   
    PRE:bm, hm,
           LOG.rep lxp F (LOG.ActiveTxn ds ds!!) (MSLL ms) sm bm hm *
           [[ off < length (BFData f) ]] *
           [[[ ds!! ::: (Fm  * rep bxp sm ixp flist ilist frees allocc (MSCache ms) (MSICache ms) (MSDBlocks ms)) ]]] *
           [[[ flist ::: (Fi * inum |-> f) ]]] *
           [[[ (BFData f) ::: (Fd * off |-> vs) ]]] *
           [[ sync_invariant F ]] *
           [[ bm h = Some v ]]
    POST:bm', hm', RET:ms'  exists flist' f' bn ds' sm',
           LOG.rep lxp F (LOG.ActiveTxn ds' ds'!!) (MSLL ms') sm' bm' hm' *
           [[ ds' = dsupd ds bn (v, vsmerge vs) ]] *
           [[ block_belong_to_file ilist bn inum off ]] *
           [[ MSCache ms = MSCache ms' ]] *
           [[ MSAlloc ms = MSAlloc ms' ]] *
           [[ MSAllocC ms = MSAllocC ms' ]] *
           [[ MSIAllocC ms = MSIAllocC ms' ]] *
           (* spec about files on the latest diskset *)
           [[[ ds'!! ::: (Fm  * rep bxp sm ixp flist' ilist frees allocc (MSCache ms') (MSICache ms') (MSDBlocks ms')) ]]] *
           [[[ flist' ::: (Fi * inum |-> f') ]]] *
           [[[ (BFData f') ::: (Fd * off |-> (v, vsmerge vs)) ]]] *
           [[ f' = mk_bfile (updN (BFData f) off (v, vsmerge vs)) (BFAttr f) (BFCache f) ]]
    XCRASH:bm', hm',
           LOG.recover_any lxp F ds sm bm' hm' \/
           exists bn, [[ block_belong_to_file ilist bn inum off ]] *
           LOG.recover_any lxp F (dsupd ds bn (v, vsmerge vs)) (Mem.upd sm bn false) bm' hm'
    >} dwrite lxp ixp inum off h ms.
  Proof. 
    unfold dwrite.
    prestep; norml.
    denote  (list2nmem ds !!) as Hz.
    eapply block_belong_to_file_ok in Hz as Hb; eauto.
    unfold rep in *; destruct_lift Hz.
    extract; seprewrite; subst.
    denote removeN as Hx.
    setoid_rewrite listmatch_length_pimpl in Hx at 2.
    rewrite map_length in *.
    destruct_lift Hx; cancel; eauto.

    sepauto.
    denote removeN as Hx.
    setoid_rewrite listmatch_extract with (i := off) (bd := 0) in Hx; try omega.
    destruct_lift Hx.

    step.
    rewrite listmatch_extract with (i := off) (b := map _ _) by omega.
    erewrite selN_map by omega; filldef.
    (* rewrite <- surjective_pairing. *)
    cancel.

    admit.

    step.
    prestep. norm.
    unfold stars; simpl.
    erewrite LOG.rep_hashmap_subset; eauto; cancel.
    intuition simpl.
    2: sepauto. 2: sepauto.
    pred_apply; cancel.
    setoid_rewrite <- updN_selN_eq with (l := ilist) (ix := inum) at 4.
    rewrite listmatch_updN_removeN by omega.
    unfold file_match at 3; cancel; eauto.
    setoid_rewrite <- updN_selN_eq with (l := INODE.IBlocks _) (ix := off) at 3.
    erewrite map_updN by omega; filldef.
    rewrite listmatch_updN_removeN by omega.
    cancel.
    cbn; eauto.
    Search smrep put_dirty.
    rewrite <- smrep_upd.
    cancel.
    apply wordToNat_good.
    rewrite natToWord_wordToNat.
    apply in_selN.
    sepauto.
    all: eauto.

    all: rewrite <- H1; cancel; eauto.

    repeat xcrash_rewrite.
    xform_norm; xform_normr.
    cancel.

    or_r; cancel.
    xform_norm; cancel.

    cancel.
    or_l; rewrite LOG.active_intact, LOG.intact_any; auto.

    Unshelve.
    all: try easy.
    exact true.
  Admitted.


  Lemma synced_list_map_fst_map : forall (vsl : list valuset),
    synced_list (map fst vsl) = map (fun x => (fst x, nil)) vsl.
  Proof.
    unfold synced_list; induction vsl; simpl; auto.
    f_equal; auto.
  Qed.

  (*
  Theorem datasync_ok :
    forall lxp bxp ixp inum ms pr,
    {< F Fm Fi sm ds flist ilist free allocc f,
    PERM:pr
    PRE:bm, hm,
           LOG.rep lxp F (LOG.ActiveTxn ds ds!!) (MSLL ms) sm bm hm *
           [[[ ds!!  ::: (Fm  * rep bxp sm ixp flist ilist free allocc (MSCache ms) (MSICache ms) (MSDBlocks ms)) ]]] *
           [[[ flist ::: (Fi * inum |-> f) ]]] *
           [[ sync_invariant F ]]
    POST:bm', hm', RET:ms'  exists ds' flist' al sm',
           LOG.rep lxp F (LOG.ActiveTxn ds' ds'!!) (MSLL ms') sm' bm' hm' *
           [[ ds' = dssync_vecs ds al ]] *
           [[[ ds'!! ::: (Fm * rep bxp sm ixp flist' ilist free allocc (MSCache ms') (MSICache ms') (MSDBlocks ms')) ]]] *
           [[[ flist' ::: (Fi * inum |-> synced_file f) ]]] *
           [[ MSAlloc ms = MSAlloc ms' ]] *
           [[ MSCache ms = MSCache ms' ]] *
           [[ MSAllocC ms = MSAllocC ms' ]] *
           [[ MSIAllocC ms = MSIAllocC ms' ]] *
           [[ length al = length (BFILE.BFData f) /\ forall i, i < length al ->
              BFILE.block_belong_to_file ilist (selN al i 0) inum i ]]
    CRASH:bm', hm', LOG.recover_any lxp F ds sm bm' hm'
    >} datasync lxp ixp inum ms.
  Proof.
    unfold datasync, synced_file, rep.
    step.
    (* I don't know how to solve these obligations *)
    admit.
    admit.

    step.
    prestep; norm.
    unfold stars; simpl.
    erewrite LOG.rep_hashmap_subset; eauto; cancel.
    intuition eauto.
    pred_apply.
    cancel.
    erewrite arrayN_except by (autorewrite with core; sepauto).
    erewrite selN_combine by eauto.
    cbn; cancel.

    seprewrite.
    rewrite arrayN_file_match_length_piff in * by (autorewrite with core; sepauto).
    rewrite arrayN_file_match_iattr_pimpl in * by (autorewrite with core; sepauto).
    destruct_lifts.
    safestep.
    5: sepauto.
    all: autorewrite with lists; eauto.
    erewrite combine_updN_l, arrayN_except_upd by (autorewrite with core; sepauto).
    cbn; cancel; eauto.
    rewrite synced_list_map_fst_map.
    rewrite listmatch_map_l; cancel.
    autorewrite with lists; eauto.

    erewrite selN_map by simplen.
    eapply block_belong_to_file_ok with (m := list2nmem ds!!); eauto.
    eassign (bxp_1, bxp_2); pred_apply; unfold rep. cancel.
    repeat erewrite fst_pair by eauto.
    cancel. eauto. simplen. simplen.
    apply list2nmem_ptsto_cancel.
    autorewrite with lists in *.
    omega.

    rewrite LOG.active_intact, LOG.intact_any; auto.
  Unshelve.
    all: eauto.
    all: exact ($0, nil).
  Qed.
  *)

  Hint Extern 1 ({{_|_}} Bind (init _ _ _ _ _) _) => apply init_ok : prog.
  Hint Extern 1 ({{_|_}} Bind (getlen _ _ _ _) _) => apply getlen_ok : prog.
  Hint Extern 1 ({{_|_}} Bind (getattrs _ _ _ _) _) => apply getattrs_ok : prog.
  Hint Extern 1 ({{_|_}} Bind (setattrs _ _ _ _ _) _) => apply setattrs_ok : prog.
  Hint Extern 1 ({{_|_}} Bind (updattr _ _ _ _ _) _) => apply updattr_ok : prog.
  Hint Extern 1 ({{_|_}} Bind (read _ _ _ _ _) _) => apply read_ok : prog.
  Hint Extern 1 ({{_|_}} Bind (write _ _ _ _ _ _) _) => apply write_ok : prog.
  Hint Extern 1 ({{_|_}} Bind (dwrite _ _ _ _ _ _) _) => apply dwrite_ok : prog.
  Hint Extern 1 ({{_|_}} Bind (grow _ _ _ _ _ _) _) => apply grow_ok : prog.
  Hint Extern 1 ({{_|_}} Bind (shrink _ _ _ _ _ _) _) => apply shrink_ok : prog.
  (* Hint Extern 1 ({{_}} Bind (datasync _ _ _ _) _) => apply datasync_ok : prog. *)
  Hint Extern 1 ({{_|_}} Bind (sync _ _ _) _) => apply sync_ok : prog.
  Hint Extern 1 ({{_|_}} Bind (sync_noop _ _ _) _) => apply sync_noop_ok : prog.
  Hint Extern 0 (okToUnify (rep _ _ _ _ _ _ _ _ _ _) (rep _ _ _ _ _ _ _ _ _ _)) => constructor : okToUnify.


  Definition read_array lxp ixp inum a i ms :=
    let^ (ms, r) <- read lxp ixp inum (a + i) ms;;
    Ret ^(ms, r).

  Definition write_array lxp ixp inum a i v ms :=
    ms <- write lxp ixp inum (a + i) v ms;;
    Ret ms.

  Theorem read_array_ok :
    forall lxp bxp ixp inum a i ms pr,
    {< F Fm Fi Fd m0 sm m flist ilist free allocc f vsl,
    PERM:pr   
    PRE:bm, hm,
           LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms) sm bm hm *
           [[[ m ::: (Fm * rep bxp sm ixp flist ilist free allocc (MSCache ms) (MSICache ms) (MSDBlocks ms)) ]]] *
           [[[ flist ::: (Fi * inum |-> f) ]]] *
           [[[ (BFData f) ::: Fd * arrayN (@ptsto _ addr_eq_dec _) a vsl ]]] *
           [[ i < length vsl]]
    POST:bm', hm', RET:^(ms', r)
           LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms') sm bm' hm' *
           [[[ m ::: (Fm * rep bxp sm ixp flist ilist free allocc (MSCache ms') (MSICache ms') (MSDBlocks ms')) ]]] *
           [[ bm' r = Some (fst (selN vsl i valuset0)) ]] *
           [[ MSAlloc ms = MSAlloc ms' ]] *
           [[ MSCache ms = MSCache ms' ]] *
           [[ MSIAllocC ms = MSIAllocC ms' ]] *
           [[ MSAllocC ms = MSAllocC ms' ]] *
           [[ MSDBlocks ms = MSDBlocks ms' ]]
    CRASH:bm', hm',  exists ms',
           LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms') sm bm' hm'
    >} read_array lxp ixp inum a i ms.
  Proof. 
    unfold read_array.
    prestep.
    intros m Hm.
    destruct_lift Hm.
    repeat eexists.
    pred_apply; norm.
    cancel.
    intuition.

    denote (arrayN _ a dummy12) as Hx.
    eassign dummy11.
    destruct (list2nmem_arrayN_bound dummy12 _ Hx); subst; simpl in *; try omega.
    eauto.
    eauto.
    pred_apply.
    rewrite isolateN_fwd with (i:=i) by auto.
    cancel.
    step.
    step.
    erewrite LOG.rep_hashmap_subset; eauto.
  Unshelve.
    eauto.
    intros; exact emp.
  Qed.


  Theorem write_array_ok :
    forall lxp bxp ixp inum a i h ms pr,
    {< F Fm Fi Fd m0 sm m flist ilist free allocc f v vsl,
    PERM:pr   
    PRE:bm, hm,
           LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms) sm bm hm *
           [[[ m ::: (Fm * rep bxp sm ixp flist ilist free allocc (MSCache ms) (MSICache ms) (MSDBlocks ms)) ]]] *
           [[[ flist ::: (Fi * inum |-> f) ]]] *
           [[[ (BFData f) ::: Fd * arrayN (@ptsto _ addr_eq_dec _) a vsl ]]] *
           [[ i < length vsl]] *
           [[ bm h = Some v ]]
    POST:bm', hm', RET:ms' exists m' flist' f',
           LOG.rep lxp F (LOG.ActiveTxn m0 m') (MSLL ms') sm bm' hm' *
           [[[ m' ::: (Fm * rep bxp sm ixp flist' ilist free allocc (MSCache ms') (MSICache ms') (MSDBlocks ms')) ]]] *
           [[[ flist' ::: (Fi * inum |-> f') ]]] *
           [[[ (BFData f') ::: Fd * arrayN (@ptsto _ addr_eq_dec _) a (updN vsl i (v, nil)) ]]] *
           [[ f' = mk_bfile (updN (BFData f) (a + i) (v, nil)) (BFAttr f) (BFCache f) ]] *
           [[ MSAlloc ms = MSAlloc ms' ]] *
           [[ MSCache ms = MSCache ms' ]] *
           [[ MSIAllocC ms = MSIAllocC ms' ]] *
           [[ MSAllocC ms = MSAllocC ms' ]]
           (* This doesn't seem true. Dirty blocks are different now. 
            * [[ MSDBlocks ms = MSDBlocks ms' ]] *)
    CRASH:bm', hm',  LOG.intact lxp F m0 sm bm' hm'
    >} write_array lxp ixp inum a i h ms.
  Proof. 
    unfold write_array.
    prestep.
    intros m Hm.
    destruct_lift Hm.
    repeat eexists.
    pred_apply; norm.
    cancel.
    intuition.
    
    eassign dummy11.
    denote (arrayN _ a _) as Hx.
    destruct (list2nmem_arrayN_bound _ _ Hx); subst; simpl in *; try omega.
    eauto.
    eauto.
    pred_apply; rewrite isolateN_fwd with (i:=i) by auto; filldef; cancel.
    eauto.

    step.
    step.
    erewrite LOG.rep_hashmap_subset; eauto.
    pred_apply; rewrite <- isolateN_bwd_upd by auto; cancel.
  Unshelve.
    all: eauto.
    intros; exact emp.
    exact nil.
  Qed.


  Hint Extern 1 ({{_|_}} Bind (read_array _ _ _ _ _ _) _) => apply read_array_ok : prog.
  Hint Extern 1 ({{_|_}} Bind (write_array _ _ _ _ _ _ _) _) => apply write_array_ok : prog.


  Definition read_range lxp ixp inum a nr ms0 :=
    let^ (ms, r) <- ForN i < nr
    Blockmem bm
    Hashmap hm
    Ghost [ bxp F Fm Fi Fd crash m0 sm m flist ilist frees allocc f vsl ]
    Loopvar [ ms pf ]
    Invariant
      LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms) sm bm hm *
      [[[ m ::: (Fm * rep bxp sm ixp flist ilist frees allocc (MSCache ms) (MSICache ms) (MSDBlocks ms)) ]]] *
      [[[ flist ::: (Fi * inum |-> f) ]]] *
      [[[ (BFData f) ::: Fd * arrayN (@ptsto _ addr_eq_dec _) a vsl ]]] *
      [[ extract_blocks bm (rev pf) = firstn i (map fst vsl) ]] *
      [[ MSAlloc ms = MSAlloc ms0 ]] *
      [[ MSCache ms = MSCache ms0 ]] *
      [[ MSIAllocC ms = MSIAllocC ms0 ]] *
      [[ MSAllocC ms = MSAllocC ms0 ]] *
      [[ MSDBlocks ms = MSDBlocks ms0 ]] *
      [[ handles_valid bm pf ]]
    OnCrash  crash
    Begin
      let^ (ms, v) <- read_array lxp ixp inum a i ms;;
      Ret ^(ms, v::pf)
    Rof ^(ms0, nil);;
    Ret ^(ms, rev r).

Lemma handles_valid_empty:
  forall bm, handles_valid bm nil.
Proof.
  unfold handles_valid; intros; apply Forall_nil.
Qed.
         
  Theorem read_range_ok :
    forall lxp bxp ixp inum a nr ms pr,
    {< F Fm Fi Fd m0 sm m flist ilist frees allocc f vsl,
    PERM:pr   
    PRE:bm, hm,
           LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms) sm bm hm *
           [[[ m ::: (Fm * rep bxp sm ixp flist ilist frees allocc (MSCache ms) (MSICache ms) (MSDBlocks ms)) ]]] *
           [[[ flist ::: (Fi * inum |-> f) ]]] *
           [[[ (BFData f) ::: Fd * arrayN (@ptsto _ addr_eq_dec _) a vsl ]]] *
           [[ nr <= length vsl]]
    POST:bm', hm', RET:^(ms', r)
           LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms') sm bm' hm' *
           [[[ m ::: (Fm * rep bxp sm ixp flist ilist frees allocc
                               (MSCache ms') (MSICache ms') (MSDBlocks ms')) ]]] *
           [[ handles_valid bm' r ]] *
           [[ extract_blocks bm' r = firstn nr (map fst vsl) ]] *
           [[ MSAlloc ms = MSAlloc ms' ]] *
           [[ MSCache ms = MSCache ms' ]] *
           [[ MSIAllocC ms = MSIAllocC ms' ]] *
           [[ MSAllocC ms = MSAllocC ms' ]] *
           [[ MSDBlocks ms = MSDBlocks ms' ]]
    CRASH:bm', hm',  exists ms',
           LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms') sm bm' hm'
    >} read_range lxp ixp inum a nr ms.
  Proof. 
    unfold read_range.
    safestep.
    apply handles_valid_empty.
    eauto.
    eauto.

    prestep.
    intros mx Hmx.
    destruct_lift Hmx.
    repeat eexists.
    pred_apply; norm.
    cancel.
    intuition.
    eauto.
    eauto.
    eauto.
    denote (arrayN _ a vsl) as Hx.
    destruct (list2nmem_arrayN_bound vsl _ Hx); subst; simpl in *; omega.
    
    assert (m1 < length vsl).
    denote (arrayN _ a vsl) as Hx.
    destruct (list2nmem_arrayN_bound vsl _ Hx); subst; simpl in *; omega.
    step.
    safestep.
    erewrite LOG.rep_hashmap_subset; eauto.
    erewrite firstn_S_selN_expand by (rewrite map_length; auto).
    rewrite extract_blocks_app; simpl.
    rewrite H33.
    clear H34; erewrite <- extract_blocks_subset_trans; eauto.
    rewrite H20; eauto.
    erewrite selN_map; subst; eauto.
    apply handles_valid_rev_eq; auto.
    constructor.
    unfold handle_valid; eauto.
    clear H33; eapply handles_valid_subset_trans; eauto.
    rewrite <- H1; cancel; eauto.

    step.
    step.
    erewrite  LOG.rep_hashmap_subset; eauto.
    apply handles_valid_rev_eq; auto.
    eassign (false_pred(AT:=addr)(AEQ:=addr_eq_dec)(V:=valuset)).
    unfold false_pred; cancel.

  Unshelve.
    all: eauto; try exact tt; intros; try exact emp; try exact tagged_block0.
  Qed.

(*
  (* like read_range, but stops when cond is true *)
  Definition read_cond A lxp ixp inum (vfold : A -> valu -> A)
                       v0 (cond : A -> bool) ms0 :=
    let^ (ms, nr) <- getlen lxp ixp inum ms0;
    let^ (ms, r, ret) <- ForN i < nr
    Hashmap hm
    Ghost [ bxp F Fm Fi m0 sm m flist f ilist frees allocc ]
    Loopvar [ ms pf ret ]
    Invariant
      LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms) sm hm *
      [[[ m ::: (Fm * rep bxp sm ixp flist ilist frees allocc (MSCache ms) (MSICache ms) (MSDBlocks ms)) ]]] *
      [[[ flist ::: (Fi * inum |-> f) ]]] *
      [[ MSAlloc ms = MSAlloc ms0 ]] *
      [[ MSCache ms = MSCache ms0 ]] *
      [[ MSIAllocC ms = MSIAllocC ms0 ]] *
      [[ MSAllocC ms = MSAllocC ms0 ]] *
      [[ ret = None ->
        pf = fold_left vfold (firstn i (map fst (BFData f))) v0 ]] *
      [[ ret = None ->
        cond pf = false ]] *
      [[ forall v, ret = Some v ->
        cond v = true ]]
    OnCrash
      LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms) sm hm
    Begin
      If (is_some ret) {
        Ret ^(ms, pf, ret)
      } else {
        let^ (ms, v) <- read lxp ixp inum i ms;
        let pf' := vfold pf v in
        If (bool_dec (cond pf') true) {
          Ret ^(ms, pf', Some pf')
        } else {
          Ret ^(ms, pf', None)
        }
      }
    Rof ^(ms, v0, None);
    Ret ^(ms, ret).


  Theorem read_cond_ok : forall A lxp bxp ixp inum (vfold : A -> valu -> A)
                                v0 (cond : A -> bool) ms,
    {< F Fm Fi m0 sm m flist ilist frees allocc f,
    PRE:hm
           LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms) sm hm *
           [[[ m ::: (Fm * rep bxp sm ixp flist ilist frees allocc (MSCache ms) (MSICache ms) (MSDBlocks ms)) ]]] *
           [[[ flist ::: (Fi * inum |-> f) ]]] *
           [[ cond v0 = false ]]
    POST:hm' RET:^(ms', r)
           LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms') sm hm' *
           [[[ m ::: (Fm * rep bxp sm ixp flist ilist frees allocc (MSCache ms') (MSICache ms') (MSDBlocks ms')) ]]] *
           [[ MSAlloc ms = MSAlloc ms' ]] *
           [[ MSCache ms = MSCache ms' ]] *
           [[ MSIAllocC ms = MSIAllocC ms' ]] *
           [[ MSAllocC ms = MSAllocC ms' ]] *
           [[ MSDBlocks ms = MSDBlocks ms' ]] *
           ( exists v, 
             [[ r = Some v /\ cond v = true ]] \/
             [[ r = None /\ cond (fold_left vfold (map fst (BFData f)) v0) = false ]])
    CRASH:hm'  exists ms',
           LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms') sm hm'
    >} read_cond lxp ixp inum vfold v0 cond ms.
  Proof.
    unfold read_cond.
    prestep. cancel.
    safestep. eauto. eauto.

    msalloc_eq.
    step.
    step.
    step.

    eapply list2nmem_array_pick; eauto.
    step.
    step.
    step.

    rewrite firstn_S_selN_expand with (def := $0) by (rewrite map_length; auto).
    rewrite fold_left_app; simpl.
    erewrite selN_map; subst; auto.
    apply not_true_is_false; auto.

    destruct a2.
    step.
    step.
    or_r; cancel.
    denote cond as Hx; rewrite firstn_oob in Hx; auto.
    rewrite map_length; auto.
    cancel.
  Unshelve.
    all: try easy.
    try exact ($0, nil).
  Qed.
*)

  Hint Extern 1 ({{_|_}} Bind (read_range _ _ _ _ _ _) _) => apply read_range_ok : prog.
  (* Hint Extern 1 ({{_}} Bind (read_cond _ _ _ _ _ _ _) _) => apply read_cond_ok : prog. *)

  Definition grown lxp bxp ixp inum l ms0 :=
    let^ (ms, ret) <- ForN i < length l
      Blockmem bm
      Hashmap hm
      Ghost [ F Fm Fi m0 sm f ilist frees ]
      Loopvar [ ms ret ]
      Invariant
        exists m',
        LOG.rep lxp F (LOG.ActiveTxn m0 m') (MSLL ms) sm bm hm *
        [[ MSAlloc ms = MSAlloc ms0 ]] *
        [[ MSCache ms = MSCache ms0 ]] *
        [[ MSIAllocC ms = MSIAllocC ms0 ]] *
        ([[ isError ret ]] \/
         exists flist' ilist' frees' f',
         [[ ret = OK tt ]] *
         [[[ m' ::: (Fm * rep bxp sm ixp flist' ilist' frees' (MSAllocC ms) (MSCache ms) (MSICache ms) (MSDBlocks ms)) ]]] *
         [[[ flist' ::: (Fi * inum |-> f') ]]] *
         [[  f' = mk_bfile ((BFData f) ++ synced_list (firstn i (extract_blocks bm l))) (BFAttr f) (BFCache f) ]] *
         [[ ilist_safe ilist  (pick_balloc frees  (MSAlloc ms)) 
                       ilist' (pick_balloc frees' (MSAlloc ms)) ]] *
         [[ treeseq_ilist_safe inum ilist ilist' ]])
      OnCrash
        LOG.intact lxp F m0 sm bm hm
      Begin
        match ret with
        | Err e => Ret ^(ms, ret)
        | OK _ =>
          let^ (ms, ok) <- grow lxp bxp ixp inum (selN l i 0) ms;;
          Ret ^(ms, ok)
        end
      Rof ^(ms0, OK tt);;
    Ret ^(ms, ret).


  Definition truncate lxp bxp xp inum newsz ms :=
    let^ (ms, sz) <- getlen lxp xp inum ms;;
    If (lt_dec newsz sz) {
      ms <- shrink lxp bxp xp inum (sz - newsz) ms;;
      Ret ^(ms, OK tt)
    } else {
      hl <- seal_all (repeat Public (newsz - sz)) (repeat $0 (newsz - sz));;
      let^ (ms, ok) <- grown lxp bxp xp inum hl ms;;
      Ret ^(ms, ok)
    }.

  (* inlined version of reset' that calls Inode.reset *)
  Definition reset lxp bxp xp inum ms :=
    let^ (fms, sz) <- getlen lxp xp inum ms;;
    let '(al, ms, alc, ialc, icache, cache, dblocks) := (MSAlloc fms, MSLL fms, MSAllocC fms, MSIAllocC fms, MSICache fms, MSCache fms, MSDBlocks fms) in
    let^ (icache, ms, bns) <- INODE.getallbnum lxp xp inum icache ms;;
    let l := map (@wordToNat _) bns in
    cms <- BALLOCC.freevec lxp (pick_balloc bxp (negb al)) l (BALLOCC.mk_memstate ms (pick_balloc alc (negb al)));;
    let^ (icache, cms) <- INODE.reset lxp (pick_balloc bxp (negb al)) xp inum sz attr0 icache cms;;
    let dblocks := clear_dirty inum dblocks in
    Ret (mk_memstate al (BALLOCC.MSLog cms) (upd_balloc alc (BALLOCC.MSCache cms) (negb al)) ialc icache (BFcache.remove inum cache) dblocks).

  Definition reset' lxp bxp xp inum ms :=
    let^ (ms, sz) <- getlen lxp xp inum ms;;
    ms <- shrink lxp bxp xp inum sz ms;;
    ms <- setattrs lxp xp inum attr0 ms;;
    Ret (mk_memstate (MSAlloc ms) (MSLL ms) (MSAllocC ms) (MSIAllocC ms) (MSICache ms) (BFcache.remove inum (MSCache ms)) (MSDBlocks ms)).


 Theorem grown_ok :
    forall lxp bxp ixp inum hl ms pr,
    {< F Fm Fi Fd m0 sm m flist ilist frees l f,
    PERM:pr   
    PRE:bm, hm,
           LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms) sm bm hm *
           [[[ m ::: (Fm * rep bxp sm ixp flist ilist frees (MSAllocC ms) (MSCache ms) (MSICache ms) (MSDBlocks ms)) ]]] *
           [[[ flist ::: (Fi * inum |-> f) ]]] *
           [[[ (BFData f) ::: Fd ]]] *
           [[ handles_valid bm hl ]] *
           [[ extract_blocks bm hl = l ]]
    POST:bm', hm', RET:^(ms', r)
           [[ MSAlloc ms' = MSAlloc ms ]] *
           [[ MSCache ms' = MSCache ms ]] *
           [[ MSIAllocC ms = MSIAllocC ms' ]] *
           exists m',
           [[ isError r ]] * LOG.rep lxp F (LOG.ActiveTxn m0 m') (MSLL ms') sm bm' hm' \/
           [[ r = OK tt  ]] * exists flist' ilist' frees' f',
           LOG.rep lxp F (LOG.ActiveTxn m0 m') (MSLL ms') sm bm' hm' *
           [[[ m' ::: (Fm * rep bxp sm ixp flist' ilist' frees' (MSAllocC ms') (MSCache ms') (MSICache ms') (MSDBlocks ms')) ]]] *
           [[[ flist' ::: (Fi * inum |-> f') ]]] *
           [[[ (BFData f') ::: (Fd * arrayN (@ptsto _ addr_eq_dec _) (length (BFData f)) (synced_list l)) ]]] *
           [[ f' = mk_bfile ((BFData f) ++ (synced_list l)) (BFAttr f) (BFCache f) ]] *
           [[ ilist_safe ilist (pick_balloc frees (MSAlloc ms')) 
                      ilist' (pick_balloc frees' (MSAlloc ms'))  ]] *
           [[ treeseq_ilist_safe inum ilist ilist' ]]
    CRASH:bm', hm',  LOG.intact lxp F m0 sm bm' hm'
    >} grown lxp bxp ixp inum hl ms.
  Proof. 
    unfold grown; intros.
    safestep.
    unfold synced_list; simpl; rewrite app_nil_r.
    eassign f; destruct f.
    eassign F_; cancel. or_r; cancel.
    eauto.
    apply ilist_safe_refl.
    eapply treeseq_ilist_safe_refl.
    eauto. eauto.

    safestep.
    apply list2nmem_arrayN_app; eauto.
    eapply extract_blocks_selN; eauto.
    eapply handles_valid_subset_trans; eauto.
    
    safestep.
    safestep.
    erewrite LOG.rep_hashmap_subset; eauto; subst; cancel.
    destruct a3; [or_r; cancel | or_l; cancel].
    cancel.

    safestep.
    erewrite LOG.rep_hashmap_subset; eauto; subst; cancel.
    or_r; cancel.
    erewrite firstn_S_selN_expand.
    rewrite synced_list_app, <- app_assoc.
    clear H29; erewrite extract_blocks_subset_trans; eauto.
    unfold synced_list at 3; simpl; eauto.
    eapply handles_valid_subset_trans; eauto.
    rewrite extract_blocks_length; auto.
    eapply handles_valid_subset_trans; eauto.
    msalloc_eq.
    eapply ilist_safe_trans; eauto.
    eapply treeseq_ilist_safe_trans; eauto.

    all: try solve [rewrite <- H1; cancel; eauto].

    safestep.
    erewrite LOG.rep_hashmap_subset; eauto; subst; cancel.
    or_l; cancel.

    safestep.
    safestep.
    erewrite LOG.rep_hashmap_subset; eauto; subst; cancel.
    cancel.

    safestep.
    erewrite LOG.rep_hashmap_subset; eauto; subst; cancel.
    or_r; cancel.
    rewrite firstn_oob; auto.
    erewrite extract_blocks_subset_trans; eauto.
    apply list2nmem_arrayN_app; auto.
    rewrite extract_blocks_length; auto.
    eapply handles_valid_subset_trans; eauto.
    rewrite firstn_oob; auto.
    erewrite <- extract_blocks_subset_trans; eauto.
    erewrite <- extract_blocks_subset_trans; eauto.
    rewrite extract_blocks_length; auto.
    
    cancel.
    Unshelve. all: eauto; try exact tt; try exact tagged_block0.
  Qed.


  Hint Extern 1 ({{_|_}} Bind (grown _ _ _ _ _ _) _) => apply grown_ok : prog.

  Theorem truncate_ok :
    forall lxp bxp ixp inum sz ms pr,
    {< F Fm Fi m0 sm m flist ilist frees f,
    PERM:pr
    PRE:bm, hm,
           LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms) sm bm hm *
           [[[ m ::: (Fm * rep bxp sm ixp flist ilist frees (MSAllocC ms) (MSCache ms) (MSICache ms) (MSDBlocks ms)) ]]] *
           [[[ flist ::: (Fi * inum |-> f) ]]]
    POST:bm', hm', RET:^(ms', r)
           [[ MSAlloc ms = MSAlloc ms' ]] *
           [[ MSCache ms = MSCache ms' ]] *
           [[ MSIAllocC ms = MSIAllocC ms' ]] *
           exists m',
           [[ isError r ]] * LOG.rep lxp F (LOG.ActiveTxn m0 m') (MSLL ms') sm bm' hm' \/
           [[ r = OK tt  ]] * exists flist' ilist' frees' f',
           LOG.rep lxp F (LOG.ActiveTxn m0 m') (MSLL ms') sm bm' hm' *
           [[[ m' ::: (Fm * rep bxp sm ixp flist' ilist' frees' (MSAllocC ms') (MSCache ms') (MSICache ms') (MSDBlocks ms')) ]]] *
           [[[ flist' ::: (Fi * inum |-> f') ]]] *
           [[ f' = mk_bfile (setlen (BFData f) sz valuset0) (BFAttr f) (BFCache f) ]] *
           [[ ilist_safe ilist (pick_balloc frees (MSAlloc ms')) 
                         ilist' (pick_balloc frees' (MSAlloc ms'))  ]] *
           [[ sz >= Datatypes.length (BFData f) -> treeseq_ilist_safe inum ilist ilist' ]]
    CRASH:bm', hm',  LOG.intact lxp F m0 sm bm' hm'
    >} truncate lxp bxp ixp inum sz ms.
  Proof. 
    unfold truncate; intros.
    step.
    step.

    - safestep.
      msalloc_eq; cancel.
      eauto.
      
      step.
      step.
      or_r; safecancel.
      erewrite LOG.rep_hashmap_subset; eauto.
      pred_apply; cancel.
      eauto.
      rewrite setlen_inbound, Rounding.sub_sub_assoc by omega; auto.
      eauto.
      exfalso; omega.
      rewrite <- H1; cancel; eauto.

    - safestep.
      repeat rewrite repeat_length; auto.
      apply repeat_spec in H4; subst; auto.
      
      safestep.
      erewrite LOG.rep_hashmap_subset; eauto;
      erewrite LOG.rep_blockmem_subset; eauto; cancel.
      pred_apply; msalloc_eq; cancel.
      eauto.
      apply list2nmem_array.
      all: eauto.
      
      step.
      step.
      erewrite LOG.rep_hashmap_subset; eauto.
      or_l; cancel.
      step.
      erewrite LOG.rep_hashmap_subset; eauto;
      or_r; safecancel.
      rewrite setlen_oob by omega.
      unfold synced_list.
      repeat rewrite combine_repeat; eauto.
      rewrite repeat_length, combine_repeat; auto.
      rewrite <- H1; cancel; eauto.
      cancel.
    - rewrite <- H1; cancel; eauto.

      Unshelve.
      all: eauto.
  Qed.

  Theorem reset_ok :
    forall lxp bxp ixp inum ms pr,
    {< F Fm Fi m0 sm m flist ilist frees f,
    PERM:pr   
    PRE:bm, hm,
           LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms) sm bm hm *
           [[[ m ::: (Fm * rep bxp sm ixp flist ilist frees (MSAllocC ms) (MSCache ms) (MSICache ms) (MSDBlocks ms)) ]]] *
           [[[ flist ::: (Fi * inum |-> f) ]]]
    POST:bm', hm', RET:ms' exists m' flist' ilist' frees',
           LOG.rep lxp F (LOG.ActiveTxn m0 m') (MSLL ms') sm bm' hm' *
           [[[ m' ::: (Fm * rep bxp sm ixp flist' ilist' frees'
                      (MSAllocC ms') (MSCache ms') (MSICache ms') (MSDBlocks ms')) ]]] *
           [[[ flist' ::: (Fi * inum |-> bfile0) ]]] *
           [[ MSIAllocC ms = MSIAllocC ms' ]] *
           [[ MSAlloc ms = MSAlloc ms' ]] *
           [[ ilist_safe ilist  (pick_balloc frees  (MSAlloc ms'))
                         ilist' (pick_balloc frees' (MSAlloc ms')) ]] *
           [[ forall inum' def', inum' <> inum -> 
                selN ilist inum' def' = selN ilist' inum' def' ]]
    CRASH:bm', hm',  LOG.intact lxp F m0 sm bm' hm'
    >} reset lxp bxp ixp inum ms.
  Proof. 
    unfold reset; intros.
    step.
    prestep. norml.
    rewrite rep_alt_equiv with (msalloc := MSAlloc ms) in *.
    unfold rep_alt in *. destruct_lifts.
    cancel; msalloc_eq.
    sepauto.

    rewrite INODE.rep_bxp_switch in H4 by eassumption.
    step.
    rewrite INODE.inode_rep_bn_valid_piff in H4; destruct_lift H4.
    rewrite <- Forall_map; solve [intuition sepauto].

    admit.
    admit.
    (* rewrite arrayN_except by (autorewrite with core; sepauto). 
    rewrite selN_combine by sepauto.
    erewrite <- listmatch_ptsto_listpred.
    cbn; rewrite listmatch_split at 1.
    rewrite <- skipn_map_comm; cancel. *)

    prestep; norm. cancel.
    intuition eauto.
    sepauto.

    safestep.
    safestep.
    erewrite LOG.rep_hashmap_subset; eauto.
    2: sepauto.
    seprewrite.
    pred_apply.
    rewrite rep_alt_equiv with (msalloc := MSAlloc a).
    cbv [rep_alt].
    erewrite <- INODE.rep_bxp_switch by eassumption.
    unfold cuttail.
    (* nonexistent lemma *)
    (* rewrite arrayN_file_match_length_piff in * by omega; destruct_lifts.
    denote (length _ = length _) as Hx. repeat rewrite Hx.
    rewrite Nat.sub_diag. *)
    admit.
    (* erewrite combine_updN, arrayN_except_upd by (autorewrite with core; sepauto).
    cancel. *)
    (* 4:*)
    erewrite <- surjective_pairing, <- pick_upd_balloc_lift;
    auto using ilist_safe_upd_nil. admit.
    admit.
    (* There might be a better way to do this 
    repeat rewrite <- surjective_pairing.
    repeat rewrite <- pick_upd_balloc_negb.
    rewrite <- pick_negb_upd_balloc. 
    repeat rewrite <- pick_upd_balloc_lift.
    cancel. 
    autorewrite with lists; eauto.
    eapply bfcache_remove'; sepauto. 
    rewrite selN_updN_ne; auto. *)
    all: rewrite <- H1; cancel; eauto. 
    Unshelve.
    all : try easy; exact INODE.inode0.
    (* all : solve [ exact bfile0 | intros; exact emp | exact nil]. *)
  Admitted.

  Hint Extern 1 ({{_|_}} Bind (truncate _ _ _ _ _ _) _) => apply truncate_ok : prog.
  Hint Extern 1 ({{_|_}} Bind (reset _ _ _ _ _) _) => apply reset_ok : prog.


  Theorem recover_ok :
    forall ms pr,
    {< F ds sm lxp,
    PERM:pr   
    PRE:bm, hm,
      LOG.rep lxp F (LOG.NoTxn ds) ms sm bm hm *
      [[ arrayN (@ptsto _ _ _) 0 (repeat true (length ds!!)) sm ]]
    POST:bm', hm', RET:ms'
      LOG.rep lxp F (LOG.NoTxn ds) (MSLL ms') sm bm' hm' *
      [[ ms = (MSLL ms') ]] *
      [[ BFILE.MSinitial ms' ]]
      (* TODO prove smrep on recovery *)
    CRASH:bm', hm', LOG.rep lxp F (LOG.NoTxn ds) ms sm bm' hm'
    >} recover ms.
  Proof. 
    unfold recover; intros.
    step.
    step.
    erewrite LOG.rep_hashmap_subset; eauto.
    unfold MSinitial; simpl; intuition eauto.
  Qed.

  Hint Extern 1 ({{_|_}} Bind (recover _ ) _) => apply recover_ok : prog.

  Theorem cache_get_ok :
    forall inum ms pr,
    {< F Fm Fi m0 sm m lxp bxp ixp flist ilist frees allocc f,
    PERM:pr   
    PRE:bm, hm,
           LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms) sm bm hm *
           [[[ m ::: (Fm * rep bxp sm ixp flist ilist frees allocc (MSCache ms) (MSICache ms) (MSDBlocks ms)) ]]] *
           [[[ flist ::: (Fi * inum |-> f) ]]]
    POST:bm', hm', RET:^(ms', r)
           [[ ms' = ms ]] *
           LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms') sm bm' hm' *
           [[ r = BFCache f ]]
    CRASH:bm', hm',  LOG.intact lxp F m0 sm bm' hm'
    >} cache_get inum ms.
  Proof.
    unfold cache_get, rep; intros.
    prestep.
    intros m Hm.
    destruct_lift Hm.
    repeat eexists.
    pred_apply; norm.
    cancel.
    intuition.
    step.
    erewrite LOG.rep_hashmap_subset; eauto.
    destruct ms; reflexivity.
    eapply bfcache_find; eauto.
    cancel.
  Qed.

  
  Theorem cache_put_ok :
    forall inum ms c pr,
    {< F Fm Fi m0 sm m lxp bxp ixp flist ilist frees allocc f,
    PERM:pr   
    PRE:bm, hm,
           LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms) sm bm hm *
           [[[ m ::: (Fm * rep bxp sm ixp flist ilist frees allocc (MSCache ms) (MSICache ms) (MSDBlocks ms)) ]]] *
           [[[ flist ::: (Fi * inum |-> f) ]]]
    POST:bm', hm', RET:ms'
           exists f' flist',
           LOG.rep lxp F (LOG.ActiveTxn m0 m) (MSLL ms') sm bm' hm' *
           [[[ m ::: (Fm * rep bxp sm ixp flist' ilist frees allocc (MSCache ms') (MSICache ms') (MSDBlocks ms')) ]]] *
           [[[ flist' ::: (Fi * inum |-> f') ]]] *
           [[ f' = mk_bfile (BFData f) (BFAttr f) (Some c) ]] *
           [[ MSAlloc ms = MSAlloc ms' ]] *
           [[ MSIAllocC ms = MSIAllocC ms' ]] *
           [[ MSAllocC ms = MSAllocC ms' ]] *
           [[ MSDBlocks ms = MSDBlocks ms' ]] *
           [[ MSLL ms = MSLL ms' ]]
    CRASH:bm', hm',  LOG.intact lxp F m0 sm bm' hm'
    >} cache_put inum c ms.
  Proof.
    unfold cache_put, rep; intros.
    prestep.
    intros m Hm.
    destruct_lift Hm.
    repeat eexists.
    pred_apply. norm.
    cancel.
    intuition.
    prestep. norm.
    unfold stars; simpl;
    erewrite LOG.rep_hashmap_subset; eauto; cancel.
    intuition idtac.
    seprewrite.
    2: sepauto.
    pred_apply; cancel.
    unfold listmatch.
    erewrite combine_updN_l. (*rewrite arrayN_except_upd by sepauto. *)
    (* rewrite arrayN_except, selN_combine by sepauto. *)
    cancel.
    eapply listpred_updN_selN.
    rewrite combine_length_eq; auto.
    rewrite  selN_combine by sepauto; simpl.
    unfold file_match; simpl.
    cancel.
    autorewrite with lists; eauto.
    eauto using bfcache_put.
    eauto.
    cancel.
    
  Unshelve.
    all: exact INODE.inode0.
  Qed.

  Hint Extern 1 ({{_|_}} Bind (cache_get _ _) _) => apply cache_get_ok : prog.
  Hint Extern 1 ({{_|_}} Bind (cache_put _ _ _) _) => apply cache_put_ok : prog.


  (** crash and recovery *)

  Definition FSynced f : Prop :=
     forall n, snd (selN (BFData f) n valuset0) = nil.

  Definition file_crash f f' : Prop :=
    exists vs, possible_crash_list (BFData f) vs /\
    f' = mk_bfile (synced_list vs) (BFAttr f) None.

  Definition flist_crash fl fl' : Prop :=
    Forall2 file_crash fl fl'.

  Lemma flist_crash_length : forall a b,
    flist_crash a b -> length a = length b.
  Proof.
    unfold flist_crash; intros.
    eapply forall2_length; eauto.
  Qed.

  Lemma fsynced_synced_file : forall f,
    FSynced (synced_file f).
  Proof.
    unfold FSynced, synced_file, synced_list; simpl; intros.
    setoid_rewrite selN_combine; simpl.
    destruct (lt_dec n (length (BFData f))).
    rewrite repeat_selN; auto.
    rewrite map_length; auto.
    rewrite selN_oob; auto.
    rewrite repeat_length, map_length.
    apply not_lt; auto.
    rewrite repeat_length, map_length; auto.
  Qed.

  Lemma arrayN_synced_list_fsynced : forall f l,
    arrayN (@ptsto _ addr_eq_dec _) 0 (synced_list l) (list2nmem (BFData f)) ->
    FSynced f.
  Proof.
    unfold FSynced; intros.
    erewrite list2nmem_array_eq with (l' := (BFData f)) by eauto.
    setoid_rewrite synced_list_selN; simpl; auto.
  Qed.

  Lemma file_crash_attr : forall f f',
    file_crash f f' -> BFAttr f' = BFAttr f.
  Proof.
    unfold file_crash; intros.
    destruct H; intuition; subst; auto.
  Qed.

  Lemma file_crash_possible_crash_list : forall f f',
    file_crash f f' ->
    possible_crash_list (BFData f) (map fst (BFData f')).
  Proof.
    unfold file_crash; intros; destruct H; intuition subst.
    unfold synced_list; simpl.
    rewrite map_fst_combine; auto.
    rewrite repeat_length; auto.
  Qed.

  Lemma file_crash_data_length : forall f f',
    file_crash f f' -> length (BFData f) = length (BFData f').
  Proof.
    unfold file_crash; intros.
    destruct H; intuition subst; simpl.
    rewrite synced_list_length.
    apply possible_crash_list_length; auto.
  Qed.

  Lemma file_crash_synced : forall f f',
    file_crash f f' ->
    FSynced f ->
    BFData f = BFData f' /\
    BFAttr f = BFAttr f'.
  Proof.
    unfold FSynced, file_crash; intros.
    destruct H; intuition subst; simpl; eauto.
    destruct f; simpl in *.
    f_equal.
    eapply list_selN_ext.
    rewrite synced_list_length.
    apply possible_crash_list_length; auto.
    intros.
    setoid_rewrite synced_list_selN.
    rewrite surjective_pairing at 1.
    eassign tagged_block0.
    rewrite H0.
    f_equal.
    erewrite possible_crash_list_unique with (b := x); eauto.
    erewrite selN_map; eauto.
  Qed.

  Lemma file_crash_fsynced : forall f f',
    file_crash f f' ->
    FSynced f'.
  Proof.
    unfold FSynced, file_crash; intuition.
    destruct H; intuition subst; simpl.
    setoid_rewrite synced_list_selN; auto.
  Qed.

  Lemma file_crash_ptsto : forall f f' vs F a,
    file_crash f f' ->
    (F * a |-> vs)%pred (list2nmem (BFData f)) ->
    (exists v, [[ In v (vsmerge vs) ]]  *
       crash_xform F * a |=> v)%pred (list2nmem (BFData f')).
  Proof.
    unfold file_crash; intros.
    repeat deex.
    eapply list2nmem_crash_xform in H0; eauto.
    simpl. pred_apply' H0.
    xform_norm.
    rewrite crash_xform_ptsto.
    cancel.
  Qed.

  Lemma xform_file_match : forall f ino,
    crash_xform (file_match f ino) =p=> 
      exists f', [[ file_crash f f' ]] * file_match f' ino.
  Proof.
    unfold file_match, file_crash; intros.
    xform_norm.
    rewrite xform_listmatch_ptsto.
    cancel; eauto; simpl; auto.
  Qed.

  Lemma xform_file_list : forall fs inos,
    crash_xform (listmatch file_match fs inos) =p=>
      exists fs', [[ flist_crash fs fs' ]] * listmatch file_match fs' inos.
  Proof.
    unfold listmatch, pprd.
    induction fs; destruct inos; xform_norm.
    cancel. instantiate(1 := nil); simpl; auto.
    apply Forall2_nil. simpl; auto.
    inversion H0.
    inversion H0.

    specialize (IHfs inos).
    rewrite crash_xform_sep_star_dist, crash_xform_lift_empty in IHfs.
    setoid_rewrite lift_impl with (Q := length fs = length inos) at 4; intros; eauto.
    rewrite IHfs; simpl.

    rewrite xform_file_match.
    cancel.
    eassign (f' :: fs'); cancel.
    apply Forall2_cons; auto.
    simpl; omega.
  Qed.

  (*
  Lemma xform_rep : forall bxp ixp flist ilist IFs frees allocc  mscache icache,
    crash_xform (rep bxp IFs ixp flist ilist frees allocc mscache icache) =p=>
      exists flist', [[ flist_crash flist flist' ]] *
      rep bxp IFs ixp flist' ilist frees allocc (BFcache.empty _) icache.
  Proof.
    unfold rep; intros.
    xform_norm.
    rewrite INODE.xform_rep, BALLOCC.xform_rep, BALLOCC.xform_rep.
    rewrite xform_file_list.
    cancel.

    rewrite locked_eq; unfold cache_rep.
    denote cache_rep as Hc; clear Hc.
    generalize dependent flist. generalize 0.
    induction fs'; simpl in *; intros.
    eapply BFM.mm_init.
    denote flist_crash as Hx; inversion Hx; subst.
    denote! (file_crash _ _) as Hy; inversion Hy; intuition subst.
    simpl.
    eapply pimpl_trans. apply pimpl_refl. 2: eapply IHfs'. cancel.
    eauto.

  Unshelve.
    all: eauto.
  Qed.
*)
  Lemma xform_file_match_ptsto : forall F a vs f ino,
    (F * a |-> vs)%pred (list2nmem (BFData f)) ->
    crash_xform (file_match f ino) =p=>
      exists f' v, file_match f' ino *
      [[ In v (vsmerge vs) ]] *
      [[ (crash_xform F * a |=> v)%pred (list2nmem (BFData f')) ]].
  Proof.
    unfold file_crash, file_match; intros.
    xform_norm.
    rewrite xform_listmatch_ptsto.
    xform_norm.
    pose proof (list2nmem_crash_xform _ H1 H) as Hx.
    apply crash_xform_sep_star_dist in Hx.
    rewrite crash_xform_ptsto in Hx; destruct_lift Hx.

    norm.
    eassign (mk_bfile (synced_list l) (BFAttr f) (BFCache f)); cancel.
    eassign (dummy).
    intuition subst; eauto.
  Qed.

  Lemma xform_rep_file : forall F bxp ixp fs f i ilist sm frees allocc mscache icache dblocks,
    (F * i |-> f)%pred (list2nmem fs) ->
    crash_xform (rep bxp sm ixp fs ilist frees allocc mscache icache dblocks) =p=>
      exists fs' f',  [[ flist_crash fs fs' ]] * [[ file_crash f f' ]] *
      rep bxp sm ixp fs' ilist frees allocc (BFcache.empty _) icache dblocks *
      [[ (arrayN_ex (@ptsto _ addr_eq_dec _) fs' i * i |-> f')%pred (list2nmem fs') ]].
  Proof.
    unfold rep; intros.
    xform_norm.
    rewrite INODE.xform_rep, BALLOCC.xform_rep, BALLOCC.xform_rep.
    rewrite xform_file_list.
    cancel.
    erewrite list2nmem_sel with (x := f) by eauto.
    apply forall2_selN; eauto.
    eapply list2nmem_inbound; eauto.

    rewrite locked_eq; unfold cache_rep.
    denote cache_rep as Hc; clear Hc.
    denote list2nmem as Hc; clear Hc.
    generalize dependent fs. generalize 0.
    induction fs'; simpl in *; intros.
    eapply BFM.mm_init.
    denote! (flist_crash _ _) as Hx; inversion Hx; subst.
    denote! (file_crash _ _) as Hy; inversion Hy; intuition subst.
    simpl.
    eapply pimpl_trans. apply pimpl_refl. 2: eapply IHfs'. cancel.
    eauto.

    apply list2nmem_ptsto_cancel.
    erewrite <- flist_crash_length; eauto.
    eapply list2nmem_inbound; eauto.
    Unshelve. all: eauto.
  Qed.

 Lemma xform_rep_file_pred : forall (F Fd : pred) bxp ixp fs f i ilist sm frees allocc mscache icache dblocks,
    (F * i |-> f)%pred (list2nmem fs) ->
    (Fd (list2nmem (BFData f))) ->
    crash_xform (rep bxp sm ixp fs ilist frees allocc mscache icache dblocks) =p=>
      exists fs' f',  [[ flist_crash fs fs' ]] * [[ file_crash f f' ]] *
      rep bxp sm ixp fs' ilist frees allocc (BFcache.empty _) icache dblocks *
      [[ (arrayN_ex (@ptsto _ addr_eq_dec _) fs' i * i |-> f')%pred (list2nmem fs') ]] *
      [[ (crash_xform Fd)%pred (list2nmem (BFData f')) ]].
  Proof.
    intros.
    rewrite xform_rep_file by eauto.
    cancel. eauto.
    unfold file_crash in *.
    repeat deex; simpl.
    eapply list2nmem_crash_xform; eauto.
  Qed.

  Lemma xform_rep_off : forall Fm Fd bxp ixp ino off f fs vs ilist sm frees allocc mscache icache dblocks,
    (Fm * ino |-> f)%pred (list2nmem fs) ->
    (Fd * off |-> vs)%pred (list2nmem (BFData f)) ->
    crash_xform (rep bxp sm ixp fs ilist frees allocc mscache icache dblocks) =p=>
      exists fs' f' v, [[ flist_crash fs fs' ]] * [[ file_crash f f' ]] *
      rep bxp sm ixp fs' ilist frees allocc (BFcache.empty _) icache dblocks * [[ In v (vsmerge vs) ]] *
      [[ (arrayN_ex (@ptsto _ addr_eq_dec _) fs' ino * ino |-> f')%pred (list2nmem fs') ]] *
      [[ (crash_xform Fd * off |=> v)%pred (list2nmem (BFData f')) ]].
  Proof.
    Opaque vsmerge.
    intros.
    rewrite xform_rep_file by eauto.
    xform_norm.
    eapply file_crash_ptsto in H0; eauto.
    destruct_lift H0.
    cancel; eauto.
    Transparent vsmerge.
  Qed.

  Lemma flist_crash_clear_caches : forall f f',
    flist_crash f f' ->
    clear_caches f' = f'.
  Proof.
    unfold flist_crash, clear_caches, clear_cache.
    induction f; simpl; intros.
    - inversion H; subst; eauto.
    - inversion H; subst; eauto.
      simpl.
      rewrite IHf by eauto; f_equal.
      inversion H2; intuition subst; simpl; eauto.
  Qed.

  Lemma freepred_file_crash : forall f f',
    file_crash f f' -> freepred f -> freepred f'.
  Proof.
    unfold file_crash, freepred, bfile0; intros.
    deex.
    f_equal.
    simpl in *.
    eapply possible_crash_list_length in H1.
    destruct vs; simpl in *; eauto.
    omega.
  Qed.

  Lemma freepred_bfile0 : freepred bfile0.
  Proof.
    unfold freepred; eauto.
  Qed.

  Hint Resolve freepred_bfile0.

End BFILE.


Ltac msalloc_eq := BFILE.msalloc_eq.