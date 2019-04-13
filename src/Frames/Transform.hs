{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeOperators       #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE PolyKinds           #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE DerivingVia         #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -fwarn-incomplete-patterns #-}
module Frames.Transform
  (
    mutate    
  , transform
  , fieldEndo
  , recordSingleton
  , dropColumn
  , dropColumns
  , retypeColumn
  , reshapeRowSimple
  , FieldDefaults (..)
  , DefaultRecord (..)
  -- unused/deprecated
  , BinaryFunction(..)
  , bfApply
  , bfPlus
  , bfLHS
  , bfRHS
  ) where

--import qualified Control.Newtype as N
import           Control.Applicative   ((<|>))
import qualified Data.Text            as T
import qualified Data.Vinyl           as V
import           Data.Vinyl.TypeLevel as V --(type (++), Snd)
import           Data.Vinyl.Functor   (Lift(..), Identity(..), Compose(..))
import qualified Frames               as F
import           Frames.Melt          (RDeleteAll, ElemOf)

import           GHC.TypeLits         (KnownSymbol, Symbol)

-- |  mutation functions

-- | Type preserving single-field mapping
fieldEndo :: forall x rs. (V.KnownField x, ElemOf rs x) => (Snd x -> Snd x) -> F.Record rs -> F.Record rs
fieldEndo f r = F.rputField @x (f $ F.rgetField @x r) r

-- | replace subset with a calculated different set of fields
transform :: forall rs as bs. (as F.⊆ rs, RDeleteAll as rs F.⊆ rs)
             => (F.Record as -> F.Record bs) -> F.Record rs -> F.Record (RDeleteAll as rs V.++ bs)
transform f xs = F.rcast @(RDeleteAll as rs) xs `F.rappend` f (F.rcast xs)

-- | append calculated subset 
mutate :: forall rs bs. (F.Record rs -> F.Record bs) -> F.Record rs -> F.Record (rs V.++ bs)
mutate f xs = xs `F.rappend` f xs 

recordSingleton :: forall af s a. (KnownSymbol s, af ~ '(s,a)) => a -> F.Record '[af]
recordSingleton a = a F.&: V.RNil

dropColumn :: forall x rs. (F.RDelete x rs F.⊆ rs) => F.Record rs -> F.Record (F.RDelete x rs)
dropColumn = F.rcast

dropColumns :: forall xs rs. (RDeleteAll xs rs F.⊆ rs) => F.Record rs -> F.Record (RDeleteAll xs rs)
dropColumns = F.rcast

-- change a column "name" at the type level
retypeColumn :: forall x y rs. ( V.KnownField x
                               , V.KnownField y
                               , V.Snd x ~ V.Snd y
                               , ElemOf rs x
                               , F.RDelete x rs F.⊆ rs)
  => F.Record rs -> F.Record (F.RDelete x rs V.++ '[y])
retypeColumn = transform @rs @'[x] @'[y] (\r -> (F.rgetField @x r F.&: V.RNil))



-- This is an anamorphic step.
-- You could also use meltRow here.  That is also (Record as -> [Record bs])
-- requires typeApplications for ss
reshapeRowSimple :: forall ss ts cs ds. (ss F.⊆ ts)
                 => [F.Record cs] -- list of classifier values
                 -> (F.Record cs -> F.Record ts -> F.Record ds)
                 -> F.Record ts
                 -> [F.Record (ss V.++ cs V.++ ds)]                
reshapeRowSimple classifiers newDataF r = 
  let ids = F.rcast r :: F.Record ss
  in flip fmap classifiers $ \c -> (ids F.<+> c) F.<+> newDataF c r  

--
data FieldDefaults =
  FieldDefaults
  {
    boolDefault :: Maybe Bool
  , intDefault :: Maybe Int
  , doubleDefault :: Maybe Double
  , textDefault :: Maybe T.Text
  }

class DefaultField a where
  defaultField :: (V.KnownField t, V.Snd t ~ a) => FieldDefaults -> (Maybe F.:. F.ElField) t -> (Maybe F.:. F.ElField) t

instance DefaultField Bool where
  defaultField d x = Compose $ fmap V.Field $ (fmap V.getField $ getCompose x) <|> (boolDefault d)
  
instance DefaultField Int where
  defaultField d x = Compose $ fmap V.Field $ (fmap V.getField $ getCompose x) <|> (intDefault d)
  
instance DefaultField Double where
  defaultField d x = Compose $ fmap V.Field $ (fmap V.getField $ getCompose x) <|> (doubleDefault d)

instance DefaultField T.Text where
  defaultField d x = Compose $ fmap V.Field $ (fmap V.getField $ getCompose x) <|> (textDefault d)

class DefaultRecord rs where
  defaultRecord :: FieldDefaults -> F.Rec (Maybe F.:. F.ElField) rs -> F.Rec (Maybe F.:. F.ElField) rs

instance DefaultRecord '[] where
  defaultRecord _ V.RNil = V.RNil

instance (DefaultRecord rs, V.KnownField t, DefaultField (V.Snd t)) => DefaultRecord  (t ': rs) where
  defaultRecord d (x V.:& xs) = defaultField d x V.:& defaultRecord d xs 

-- for aggregations

newtype BinaryFunction a = BinaryFunction { appBinaryFunction :: a -> a -> a } 

bfApply :: forall (rs :: [(Symbol,*)]). (V.RMap (V.Unlabeled rs), V.RApply (V.Unlabeled rs), V.StripFieldNames rs)
         => F.Rec BinaryFunction (V.Unlabeled rs) -> (F.Record rs -> F.Record rs -> F.Record rs)
bfApply binaryFunctions xs ys = V.withNames $ V.rapply applyLHS (V.stripNames ys) where
  applyLHS = V.rzipWith (\bf ia -> Lift (\ib -> Identity $ appBinaryFunction bf (getIdentity ia) (getIdentity ib))) binaryFunctions (V.stripNames xs)

bfPlus :: Num a => BinaryFunction a
bfPlus = BinaryFunction (+)

bfLHS :: BinaryFunction a
bfLHS = BinaryFunction const

bfRHS :: BinaryFunction a
bfRHS = BinaryFunction $ flip const
