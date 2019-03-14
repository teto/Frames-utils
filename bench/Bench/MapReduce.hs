{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE AllowAmbiguousTypes       #-}
{-# LANGUAGE DataKinds                 #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE GADTs                     #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE TypeApplications          #-}
{-# LANGUAGE TypeOperators             #-}
{-# LANGUAGE ConstraintKinds           #-}
module Bench.MapReduce
  ( benchMapReduce
  )
where

import           Criterion
import           Control.DeepSeq                ( NFData(rnf) )

import qualified Frames.MapReduce              as MR
import qualified Control.MapReduce.Parallel    as MRP
import qualified Frames.Aggregations.Folds     as FF
import qualified Frames.Transform              as FT
import           Frames.Table                   ( blazeTable
                                                , RecordColonnade
                                                )

import qualified Control.Foldl                 as FL
import qualified Data.List                     as List
import qualified Data.Profunctor               as P
import qualified Data.Text                     as T
import qualified Data.Vinyl                    as V
import qualified Data.Vector.Storable          as V
import qualified Frames                        as F

import qualified Numeric.LinearAlgebra         as LA
import           Numeric.LinearAlgebra          ( R
                                                , Matrix
                                                )




createData :: Int -> IO (F.FrameRec AllCols, String)
createData rows = do
  let vars   = unweighted rows
      yNoise = 1.0
      unweighted n = List.replicate n (1.0)
  dat <- noisyData vars yNoise (LA.fromList [1.0, 2.2]) >>= makeFrame vars
  let nonsense = "Nonsense"
  return (dat,nonsense)


benchAvgXYByLabel dat = bgroup
  (show $ FL.fold FL.length dat)
  [ bench "serial (strict)" $ nf (FL.fold $ mrAvgXYByLabel MR.groupMapStrict) dat
  , bench "serial (lazy)" $ nf (FL.fold $ mrAvgXYByLabel MR.groupMapLazy) dat
  , bench "serial (hash)" $ nf (FL.fold $ mrAvgXYByLabel MR.groupHashMap) dat
  , bench "parallel reduce (strict)" $ nf (FL.fold $ mrAvgXYByLabel MRP.parReduceGroupMap) dat
--  , bench "parallel reduce/combine" $ nf (FL.fold mrAvgXYByLabelP2) dat
  ]

benchMapReduce :: Benchmark
benchMapReduce = bgroup
  "MapReduce"
  [ bgroup "AvgXYByLabel" $ fmap
      (\x -> env (createData x) (\ ~(dat,nonsense) -> benchAvgXYByLabel dat))
      [5000, 20000]
  ]

type Label = "label" F.:-> T.Text
type Y = "y" F.:-> Double
type X = "x" F.:-> Double
type ZM = "zMaybe" F.:-> (Maybe Double)
type Weight = "weight" F.:-> Double
type IsDup = "is_duplicate" F.:-> Bool
type AllCols = [Label,Y,X,Weight]


-- let's make some map-reductions on Frames of AllCols

-- First some unpackings
noUnpack = MR.noUnpack
filterLabel ls = MR.filter (\r -> (F.rgetField @Label r) `List.elem` ls)
filterMinX minX = MR.filter ((>= minX) . F.rgetField @X)
editLabel f r = F.rputField @Label (f (F.rgetField @Label r)) r -- this would be better with lenses!!
unpackDup = MR.Unpack $ \r -> [r, editLabel (<> "2") r]

-- some assignings
assignToLabels = MR.assignFrame @'[Label] @'[Y, X, Weight]
assignDups = MR.assign @Ord @(F.Record '[IsDup])
  (\r -> (T.length (F.rgetField @Label r) > 1) F.&: V.RNil)
  (F.rcast @'[Y, X, Weight])

-- some gatherings
gatherLists = MR.gatherRecordList
gatherFrames = MR.gatherRecordFrame

-- some reductions
--averageF :: FL.Fold (F.FrameRec '[X,Y]) F.Record '[X,Y]
averageF = FF.foldAllConstrained @RealFloat FL.mean

--maxX :: FL.Fold (F.Record '[X]) (F.Record '[ZM])
maxX = P.dimap (F.rgetField @X) (FT.recordSingleton @ZM) FL.maximum

--maxXY :: FL.Fold (F.Record '[X,Y]) (F.Record '[MX])
maxXY = P.dimap (\r -> Prelude.max (F.rgetField @X r) (F.rgetField @Y r))
                (FT.recordSingleton @ZM)
                FL.maximum

-- put them together
--mrAvgXYByLabel :: MR.GroupMap -> FL.Fold (F.Record AllCols) (F.FrameRec AllCols)
mrAvgXYByLabel gm = MR.mapReduceFrame gm
                    noUnpack
                    assignToLabels
                    (MR.foldAndAddKey averageF)

{-
mrAvgXYByLabelStrict :: FL.Fold (F.Record AllCols) (F.FrameRec AllCols)
mrAvgXYByLabelStrict = MR.mapReduceFrame MR.groupMapStrict
                                   noUnpack
                                   assignToLabels
                                   (MR.foldAndAddKey averageF)


mrAvgXYByLabelP :: FL.Fold (F.Record AllCols) (F.FrameRec AllCols)
mrAvgXYByLabelP = MR.mapReduceFrame MRP.parReduceGroupMap
                                    noUnpack
                                    assignToLabels
                                    (MR.foldAndAddKey averageF)

mrAvgXYByLabelP2 :: FL.Fold (F.Record AllCols) (F.FrameRec AllCols)
mrAvgXYByLabelP2 = MR.mapReduceFrame
  (MRP.parAllGroupMap $ MRP.parFoldMonoidDC 100)
  noUnpack
  assignToLabels
  (MR.foldAndAddKey averageF)
-}


noisyData :: [Double] -> Double -> LA.Vector R -> IO (LA.Vector R, LA.Matrix R)
noisyData variances noiseObs coeffs = do
  -- generate random measurements
  let d    = LA.size coeffs
      nObs = List.length variances
--  xs0 <- LA.cmap (\x-> x - 0.5) <$> LA.rand nObs (d-1) -- 0 centered uniformly distributed random numbers
  let xs0 :: Matrix R =
        LA.asColumn
          $ LA.fromList
          $ [ -0.5 + (realToFrac i / realToFrac nObs) | i <- [0 .. (nObs - 1)] ]
--  xNoise <- LA.randn nObs (d-1) -- 0 centered normally (sigma=1) distributed random numbers
  let xsC = 1 LA.||| xs0
      ys0 = xsC LA.<> LA.asColumn coeffs
  yNoise <- fmap (List.head . LA.toColumns) (LA.randn nObs 1) -- 0 centered normally (sigma=1) distributed random numbers
  let ys = ys0 + LA.asColumn
        (LA.scale
          noiseObs
          (V.zipWith (*) yNoise (LA.cmap sqrt (LA.fromList variances)))
        )
  return (List.head (LA.toColumns ys), xsC)

makeFrame :: [Double] -> (LA.Vector R, LA.Matrix R) -> IO (F.FrameRec AllCols)
makeFrame vars (ys, xs) = do
  if snd (LA.size xs) /= 2
    then error
      ("Matrix of xs wrong size (" ++ show (LA.size xs) ++ ") for makeFrame")
    else return ()
  let rows     = LA.size ys
      rowIndex = [0 .. (rows - 1)]
      makeLabel :: Int -> Char
      makeLabel n = toEnum (fromEnum 'A' + n `mod` 26)
      makeRecord :: Int -> F.Record AllCols
      makeRecord n =
        T.pack [makeLabel n]
          F.&:         ys
          `LA.atIndex` n
          F.&:         xs
          `LA.atIndex` (n, 1)
          F.&:         vars
          List.!!      n
          F.&:         V.RNil -- skip bias column
  return $ F.toFrame $ makeRecord <$> rowIndex


