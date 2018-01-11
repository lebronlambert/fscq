module Interpreter where

import           Data.Word
import qualified Disk
import           Prog
import           Word
-- import qualified Crypto.Hash.SHA256 as SHA256
import qualified Data.Digest.CRC32 as CRC32
import           System.CPUTime.Rdtsc
import           System.IO (hPutStrLn, stderr)
import           Timings
import           Data.IORef

-- import qualified System.Exit
-- import qualified System.Random

-- crashRandom :: IO Int
-- crashRandom = System.Random.getStdRandom (System.Random.randomR (1, 20))

-- maybeCrash :: IO ()
-- maybeCrash = do
--   x <- crashRandom
--   -- if x == 1
--   if x == 0
--   then
--     do
--       putStrLn "CRASH!"
--       System.Exit.exitFailure
--   else
--     return ()

verbose :: Bool
verbose = False

timing :: Bool
timing = True

debugmsg :: String -> IO ()
debugmsg s =
  if verbose then
    hPutStrLn stderr s
  else
    return ()

data FscqState = FscqState
  { disk :: Disk.DiskState
  , timings :: IORef Timings }

newFscqState :: Disk.DiskState -> IO FscqState
newFscqState ds = do
  tm_ref <- newIORef emptyTimings
  return $ FscqState ds tm_ref

crc32_word_update :: Word32 -> Integer -> Coq_word -> IO Word32
crc32_word_update c sz (W w) = do
  bs <- Word.i2bs w $ fromIntegral $ (sz + 7) `div` 8
  crc32_word_update c sz (WBS bs)
crc32_word_update c sz (W64 w) = crc32_word_update c sz $ W $ fromIntegral w
crc32_word_update c _ (WBS bs) = return $ CRC32.crc32Update c bs

run_dcode :: FscqState -> Prog.Coq_prog a -> IO a
run_dcode _ (Ret r) = {-# SCC "dcode-ret" #-}do
  debugmsg $ "Done"
  return r
run_dcode FscqState{disk=ds} (Read a) = {-# SCC "dcode-read" #-} do
  debugmsg $ "Read " ++ (show a)
  val <- Disk.read_disk ds a
  return $ unsafeCoerce val
run_dcode FscqState{disk=ds} (Write a v) = do
  debugmsg $ "Write " ++ (show a) ++ " " ++ (show v)
  Disk.write_disk ds a v
  return $ unsafeCoerce ()
run_dcode FscqState{disk=ds} Sync = do
  debugmsg $ "Sync"
  Disk.sync_disk ds
  return $ unsafeCoerce ()
run_dcode FscqState{disk=ds} (Trim a) = do
  debugmsg $ "Trim " ++ (show a)
  Disk.trim_disk ds a
  return $ unsafeCoerce ()
run_dcode FscqState{disk=ds} (VarAlloc v) = do
  debugmsg $ "VarAlloc"
  i <- Disk.var_alloc ds v
  return $ unsafeCoerce i
run_dcode FscqState{disk=ds} (VarGet i) = do
  debugmsg $ "VarGet " ++ (show i)
  val <- Disk.var_get ds i
  return $ unsafeCoerce val
run_dcode FscqState{disk=ds} (VarSet i v) = do
  debugmsg $ "VarSet " ++ (show i)
  Disk.var_set ds i v
  return $ unsafeCoerce ()
run_dcode FscqState{disk=ds} (VarDelete i) = do
  debugmsg $ "VarDelete " ++ (show i)
  Disk.var_delete ds i
  return $ unsafeCoerce ()
run_dcode _ AlertModified = do
  debugmsg $ "AlertModified"
  return $ unsafeCoerce ()
run_dcode FscqState{timings=tm_ref} (Debug s n) = {-# SCC "dcode-debug" #-} do
  modifyIORef' tm_ref (insertTime s n)
  return $ unsafeCoerce ()
run_dcode _ (Rdtsc) = {-# SCC "dcode-rdtsc" #-} do
  if timing then do
    r <- rdtsc
    return $ unsafeCoerce (fromIntegral r :: Integer)
  else
    return $ unsafeCoerce (0 :: Integer)
run_dcode _ (Hash sz w) = {-# SCC "dcode-hash" #-} do
  debugmsg $ "Hash " ++ (show sz)
  c <- crc32_word_update 0 sz w
  return $ unsafeCoerce $ W $ fromIntegral c
run_dcode _ (Hash2 sz1 sz2 w1 w2) = {-# SCC "dcode-hash2" #-} do
  debugmsg $ "Hash2 " ++ (show sz1) ++ " " ++ (show sz2)
  c1 <- crc32_word_update 0 sz1 w1
  c2 <- crc32_word_update c1 sz2 w2
  return $ unsafeCoerce $ W $ fromIntegral c2
run_dcode s (Bind p1 p2) = {-# SCC "dcode-bind" #-} do
  r1 <- run_dcode s p1
  r2 <- run_dcode s (p2 r1)
  return r2

run :: FscqState -> Prog.Coq_prog a -> IO a
run = run_dcode
