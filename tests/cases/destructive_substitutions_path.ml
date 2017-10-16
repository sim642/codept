module type s = sig
  module Ext: sig end
  module Middle:sig module Ext2: sig end end
  module Inner:sig end
end

module Void = struct end

module F(): s with module Ext := Void and module Middle.Ext2 := Void =
struct
  module Inner = struct end
  module Middle = struct end
end

module M = F()
open M
open Inner
open Middle

module A = struct open Ext end
module B = struct open Ext2 end
