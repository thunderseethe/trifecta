-----------------------------------------------------------------------------
-- |
-- Copyright   :  (C) 2011-2019 Edward Kmett
-- License     :  BSD-style (see the file LICENSE)
--
-- Maintainer  :  Edward Kmett <ekmett@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable
--
----------------------------------------------------------------------------
module Text.Trifecta.Util.Combinators
  ( argmin
  , argmax
  -- * ByteString conversions
  , fromLazy
  , toLazy
  , takeLine
  , (<$!>)
  ) where

import Data.Text as Strict
import Data.Text.Lazy as Lazy
import Data.Text.Internal.Fusion as Stream
import Data.Text.Internal.Lazy.Fusion as LazyStream

argmin :: Ord b => (a -> b) -> a -> a -> a
argmin f a b
  | f a <= f b = a
  | otherwise = b
{-# INLINE argmin #-}

argmax :: Ord b => (a -> b) -> a -> a -> a
argmax f a b
  | f a > f b = a
  | otherwise = b
{-# INLINE argmax #-}

fromLazy :: Lazy.Text -> Strict.Text
fromLazy = Lazy.toStrict

toLazy :: Strict.Text -> Lazy.Text
toLazy = Lazy.fromStrict

takeLine :: Lazy.Text -> Lazy.Text
takeLine s = case Stream.findIndex (== '\n') (LazyStream.stream s) of
  Just i -> Lazy.take (fromIntegral i + 1) s
  Nothing -> s

infixl 4 <$!>
(<$!>) :: Monad m => (a -> b) -> m a -> m b
f <$!> m = do
  a <- m
  return $! f a
