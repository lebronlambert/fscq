Require Import MemCache.
Require Import AsyncDisk.

Section WriteBuffer.

  Inductive wb_entry :=
  | Written (v:valu)
  | WbMissing (* never stored in write buffer, used to represent missing entries *).

  Definition WriteBuffer:Type := Map.t wb_entry.

  Definition empty_writebuffer := Map.empty wb_entry.

  Implicit Types (wb:WriteBuffer) (a:addr).

  Definition wb_get wb a : wb_entry :=
    match Map.find a wb with
    | Some ce => ce
    | None => WbMissing
    end.

  Definition wb_add wb a v :=
    Map.add a (Written v) wb.

  Theorem wb_get_add_eq : forall wb a v,
      wb_get (wb_add wb a v) a = Written v.
  Proof.
    unfold wb_get, wb_add; intros.
    rewrite MapFacts.add_eq_o; auto.
  Qed.

  Theorem wb_get_add_neq : forall wb a a' v,
      a <> a' ->
      wb_get (wb_add wb a v) a' = wb_get wb a'.
  Proof.
    unfold wb_get, wb_add; intros.
    rewrite MapFacts.add_neq_o by auto; auto.
  Qed.

End WriteBuffer.