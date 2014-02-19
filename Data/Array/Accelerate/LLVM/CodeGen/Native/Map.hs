{-# LANGUAGE GADTs               #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ParallelListComp    #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- |
-- Module      : Data.Array.Accelerate.LLVM.CodeGen.Native.Map
-- Copyright   :
-- License     :
--
-- Maintainer  : Trevor L. McDonell <tmcdonell@nvidia.com>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--


module Data.Array.Accelerate.LLVM.CodeGen.Native.Map
  where

-- llvm-general
import LLVM.General.AST
import LLVM.General.AST.Global

-- accelerate
import Data.Array.Accelerate.Array.Sugar                        ( Array, Elt )
import Data.Array.Accelerate.Type

import Data.Array.Accelerate.LLVM.CodeGen.Arithmetic
import Data.Array.Accelerate.LLVM.CodeGen.Base
import Data.Array.Accelerate.LLVM.CodeGen.Constant
import Data.Array.Accelerate.LLVM.CodeGen.Environment
import Data.Array.Accelerate.LLVM.CodeGen.Exp
import Data.Array.Accelerate.LLVM.CodeGen.Module
import Data.Array.Accelerate.LLVM.CodeGen.Monad
import Data.Array.Accelerate.LLVM.CodeGen.Type

-- standard library
import Control.Monad.State


-- C Code
-- ======
--
-- float f(float);
--
-- void map(float* __restrict__ out, const float* __restrict__ in, const int n)
-- {
--     for (int i = 0; i < n; ++i)
--         out[i] = f(in[i]);
--
--     return;
-- }

-- Corresponding LLVM
-- ==================
--
-- define void @map(float* noalias nocapture %out, float* noalias nocapture %in, i32 %n) nounwind uwtable ssp {
--   %1 = icmp sgt i32 %n, 0
--   br i1 %1, label %.lr.ph, label %._crit_edge
--
-- .lr.ph:                                           ; preds = %0, %.lr.ph
--   %indvars.iv = phi i64 [ %indvars.iv.next, %.lr.ph ], [ 0, %0 ]
--   %2 = getelementptr inbounds float* %in, i64 %indvars.iv
--   %3 = load float* %2, align 4
--   %4 = tail call float @apply(float %3) nounwind
--   %5 = getelementptr inbounds float* %out, i64 %indvars.iv
--   store float %4, float* %5, align 4
--   %indvars.iv.next = add i64 %indvars.iv, 1
--   %lftr.wideiv = trunc i64 %indvars.iv.next to i32
--   %exitcond = icmp eq i32 %lftr.wideiv, %n
--   br i1 %exitcond, label %._crit_edge, label %.lr.ph
--
-- ._crit_edge:                                      ; preds = %.lr.ph, %0
--   ret void
-- }
--
-- declare float @apply(float)
--

mkMap :: forall t aenv sh a b. Elt b
      => Gamma aenv
      -> IRFun1       aenv (a -> b)
      -> IRDelayed    aenv (Array sh a)
      -> CodeGen [Kernel t aenv (Array sh b)]
mkMap aenv apply IRDelayed{..} = do
  code  <- body >> createBlocks
  return [ Kernel $ functionDefaults
             { returnType  = VoidType
             , name        = "map"
             , parameters  = (paramIn ++ paramOut, False)
             , basicBlocks = code
             } ]
  where
    arrOut      = arrayData  (undefined::Array sh b) "out"
    shOut       = arrayShape (undefined::Array sh b) "out"

    paramOut    = arrayParam "out" (undefined::Array sh b)
    paramIn     = envParam aenv

    zero        = constOp $ scalar sint 0
    one         = constOp $ num nint 1
    sint        = scalarType :: ScalarType Int
    nint        = numType    :: NumType Int

    body :: CodeGen ()
    body = do
      loop <- newBlock "loop.top"
      exit <- newBlock "loop.exit"

      -- Header: check if size of output array > 0
      n    <- foldM (mul nint) one (map local shOut)
      c    <- gt sint n zero
      top  <- cbr c loop exit

      -- Body: keep looping until i == n
      --
      -- Read an element from the array, apply the function, and store the value
      -- into the result array.
      --
      setBlock loop
      indv <- freshName
      let i = local indv
      xs   <- delayedLinearIndex [i]
      ys   <- apply xs
      writeArray arrOut i ys

      i'   <- add nint i one
      c'   <- eq sint i' n
      bot  <- cbr c' exit loop
      _    <- phi loop indv (typeOf nint) [(i', bot), (zero,top)]

      setBlock exit
      _    <- terminate $ Do (Ret Nothing [])
      return ()
