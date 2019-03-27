{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE RankNTypes            #-}
import           Criterion.Main
import           Criterion


import           Control.MapReduce             as MR
import           Control.MapReduce.Engines     as MRE

import           Data.Text                     as T
import           Data.List                     as L
import           Data.HashMap.Lazy             as HM
import           Data.Map                      as M
import qualified Control.Foldl                 as FL
import           Control.Arrow                  ( second )
import           Data.Foldable                 as F
import           Data.Sequence                 as Seq
import           Data.Maybe                     ( catMaybes )

createPairData :: Int -> [(Char, Int)]
createPairData n =
  let makePair k = (toEnum $ fromEnum 'A' + k `mod` 26, k `mod` 31)
  in  L.unfoldr (\m -> if m > n then Nothing else Just (makePair m, m + 1)) 0

-- For example, keep only even numbers, then compute the average of the Int for each label.
filterPF = even . snd
assignPF = id -- this is a function from the "data" to a pair (key, data-to-process).
reducePFold = FL.premap realToFrac FL.mean
reducePF k hx = (k, FL.fold reducePFold hx)
{-
resultF :: [(Char, Double)] -> Double
resultF = FL.fold FL.sum . fmap snd

wrapper
  :: (forall g . Foldable g => g (Char, Int) -> [(Char, Double)])
  -> Seq.Seq (Char, Int)
  -> Double
  -> Double
wrapper f dat mult = mult * resultF (f dat)
-}

-- the most direct way I can easily think of
direct :: Foldable g => g (Char, Int) -> [(Char, Double)]
direct =
  HM.toList
    . fmap (FL.fold reducePFold)
    . HM.fromListWith (<>)
    . fmap (second $ pure @[])
    . L.filter filterPF
    . F.toList
{-# INLINE direct #-}

directFoldl :: Foldable g => g (Char, Int) -> [(Char, Double)]
directFoldl = FL.fold
  ((fmap
     ( HM.toList
     . fmap (FL.fold reducePFold)
     . HM.fromListWith (<>)
     . fmap (second $ pure @[])
     . L.filter filterPF
     )
   )
    FL.list
  )
{-# INLINE directFoldl #-}

directFoldl2 :: Foldable g => g (Char, Int) -> [(Char, Double)]
directFoldl2 = FL.fold
  ((fmap
     ( fmap (uncurry reducePF)
     . HM.toList
     . HM.fromListWith (<>)
     . fmap (second $ pure @[])
     . L.filter filterPF
     )
   )
    FL.list
  )

directFoldl3 :: Foldable g => g (Char, Int) -> [(Char, Double)]
directFoldl3 =
  fmap (uncurry reducePF)
    . HM.toList
    . HM.fromListWith (<>)
    . fmap (second $ pure @[])
    . L.filter filterPF
    . FL.fold FL.list

{-# INLINE directFoldl2 #-}
{-
directWithListUnpack :: Foldable g => g (Char, Int) -> [(Char, Double)]
directWithListUnpack = FL.fold
  (fmap
    ( fmap (second (FL.fold reducePFold))
    . HM.toList
    . HM.fromListWith (<>)
    . fmap (second $ pure @[])
    . mconcat
    . fmap (F.toList)
    . fmap (\x -> if filterPF x then [x] else [])
    )
    FL.list
  )


directWithMaybeUnpack :: Foldable g => g (Char, Int) -> [(Char, Double)]
directWithMaybeUnpack =
  HM.toList
    . fmap (FL.fold reducePFold)
    . HM.fromListWith (<>)
    . fmap (second $ pure @[])
    . mconcat
    . fmap (F.toList)
    . fmap (\x -> if filterPF x then Just x else Nothing)
    . F.toList
-}
mrListEngine :: Foldable g => g (Char, Int) -> [(Char, Double)]
mrListEngine = FL.fold
  (MRE.lazyHashMapListEngine
    (MR.Unpack $ \x -> if filterPF x then [x] else [])
    (MR.Assign id)
    (MRE.Reduce reducePF)
  )
{-
-- the default map-reduce, using a HashMap as the gatherer since the key is hashable
mapAllGatherEach :: Foldable g => g (Char, Int) -> [(Char, Double)]
mapAllGatherEach = FL.fold
  (MR.basicListFold @Hashable
    (MR.filterUnpack filterPF)
    (MR.Assign assignPF)
    (MR.foldAndRelabel reducePFold (\k m -> [(k, m)]))
  )

-- use the basic parallel apparatus
mapAllGatherEachP :: Foldable g => g (Char, Int) -> [(Char, Double)]
mapAllGatherEachP = FL.fold
  (MR.parBasicListHashableFold
    1000
    6
    (MR.filterUnpack filterPF)
    (MR.Assign assignPF)
    (MR.foldAndRelabel reducePFold (\k m -> [(k, m)]))
  )

-- this should be pretty close to what the (serial) mapreduce code will do
-- in particular, do all unpacking and assigning, then make a sequence of the result and then group that.
copySteps :: (Functor g, Foldable g) => g (Char, Int) -> [(Char, Double)]
copySteps =
  HM.foldrWithKey (\k m l -> (k, m) : l) []
    . fmap (FL.fold reducePFold)
    . HM.fromListWith (<>)
    . F.toList
    . fmap (second $ pure @[])
    . F.fold
    . fmap (Seq.fromList . F.toList . fmap assignPF)
    . fmap (\x -> if filterPF x then Just x else Nothing) --L.filter filterF


-- for use in the below versions which move away from the default settings
-- this is the same as the default gatherer, using a hashmap and gathering the data into a list while grouping and before reducing
g = MR.defaultHashableGatherer (pure @[])

-- try the variations on unpack, assign and fold order
-- for all but mapAllGatherEach, we need unpack to unpack to a monoid
monoidUnpackF =
  let f !x = if filterPF x then Seq.singleton x else Seq.empty in MR.Unpack f


mapAllGatherEach2 :: Foldable g => g (Char, Int) -> [(Char, Double)]
mapAllGatherEach2 = FL.fold
  (MR.mapReduceFold MR.uagListFold
                    (MR.gathererListToLazyHashMap (pure @[]))
                    (MR.filterUnpack filterPF)
                    (MR.Assign assignPF)
                    (MR.foldAndRelabel reducePFold (\k m -> [(k, m)]))
  )

mapEach :: Foldable g => g (Char, Int) -> [(Char, Double)]
mapEach = FL.fold
  (MR.mapReduceFold MR.uagMapEachFold
                    g
                    monoidUnpackF
                    (MR.Assign assignPF)
                    (MR.foldAndRelabel reducePFold (\k m -> [(k, m)]))
  )

mapAllGatherOnce :: Foldable g => g (Char, Int) -> [(Char, Double)]
mapAllGatherOnce = FL.fold
  (MR.mapReduceFold MR.uagMapAllGatherOnceFold
                    g
                    monoidUnpackF
                    (MR.Assign assignPF)
                    (MR.foldAndRelabel reducePFold (\k m -> [(k, m)]))
  )
-}

benchOne dat = bgroup
  "Task 1, on (Char, Int) "
  [ bench "direct" $ nf direct dat
  , bench "directFoldl2" $ nf directFoldl2 dat
  , bench "directFoldl3" $ nf directFoldl3 dat
  , bench "ListEngine" $ nf mrListEngine dat
{-  , bench "directFoldl2" $ nf directFoldl2 dat
  , bench "directWithListUnpack" $ nf directWithListUnpack dat
  , bench "directWithMaybeUnpack" $ nf directWithMaybeUnpack dat
  , bench "map-reduce-fold (mapAllGatherEach, filter with Maybe)"
    $ nf mapAllGatherEach dat -}
  ]
{-
-- a more complex row type
createMapRows :: Int -> Seq.Seq (M.Map T.Text Int)
createMapRows n =
  let makeRow k = if even k
        then M.fromList [("A", k), ("B", k `mod` 47), ("C", k `mod` 13)]
        else M.fromList [("A", k), ("B", k `mod` 47)]
  in  Seq.unfoldr (\m -> if m > n then Nothing else Just (makeRow m, m + 1)) 0

-- unpack: if A and B and C are present, unpack to Just (A,B,C), otherwise Nothing
unpackMF :: M.Map T.Text Int -> Maybe (Int, Int, Int)
unpackMF m = do
  a <- M.lookup "A" m
  b <- M.lookup "B" m
  c <- M.lookup "C" m
  return (a, b, c)

-- group by the value of "C"
assignMF :: (Int, Int, Int) -> (Int, (Int, Int))
assignMF (a, b, c) = (c, (a, b))

-- compute the average of the sum of the values in A and B for each group
reduceMFold :: FL.Fold (Int, Int) Double
reduceMFold = let g (x, y) = realToFrac (x + y) in FL.premap g FL.mean

-- return [(C, <A+B>)]

directM :: Foldable g => g (M.Map T.Text Int) -> [(Int, Double)]
directM =
  M.toList
    . fmap (FL.fold reduceMFold)
    . M.fromListWith (<>)
    . fmap (second (pure @[]) . assignMF)
    . catMaybes
    . fmap unpackMF
    . F.toList

basicList :: Foldable g => g (M.Map T.Text Int) -> [(Int, Double)]
basicList = FL.fold
  (MR.basicListFold @Hashable
    (MR.Unpack unpackMF)
    (MR.Assign assignMF)
    (MR.foldAndRelabel reduceMFold (\k x -> [(k, x)]))
  )

basicListP :: Foldable g => g (M.Map T.Text Int) -> [(Int, Double)]
basicListP = FL.fold
  (MR.parBasicListHashableFold
    1000
    6
    (MR.Unpack unpackMF)
    (MR.Assign assignMF)
    (MR.foldAndRelabel reduceMFold (\k x -> [(k, x)]))
  )

benchTwo dat = bgroup
  "Task 2, on Map Text Int "
  [ bench "direct" $ nf directM dat
  , bench "map-reduce-fold (basicList)" $ nf basicList dat
  , bench "map-reduce-fold (basicList, parallel)" $ nf basicListP dat
  ]
-}
main :: IO ()
main =
  defaultMain [benchOne $ createPairData 100000 {-, benchTwo $ createMapRows 100000 -}
                                               ]
