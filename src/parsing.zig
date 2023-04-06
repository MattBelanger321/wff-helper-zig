const std = @import("std");
const debug = std.debug;

const MAX_PARSE_CHILDREN = 5;

pub const ParseError = error{
    UnexpectedToken,
    NoTokensFound,

    // TerminalShiftError,
    // NonterminalShiftError,
    // ReduceError,
    InvalidSyntax,
    MatchError,
};

pub const PropositionVar = struct {
    const Self = @This();

    string: [1]u8,

    pub fn equals(self: Self, other: Self) bool {
        return self.string[0] == other.string[0];
    }
};

pub const WffOperator = enum {
    const Self = @This();

    Not, // '~'
    And, // '^'
    Or, // 'v'
    Cond, // Conditional: "=>"
    Bicond, // Biconditional: "<=>"

    pub fn getString(self: Self) []const u8 {
        return switch(self) {
            .Not => "~",
            .And => "^",
            .Or => "v",
            .Cond => "=>",
            .Bicond => "<=>",
        };
    }
};

pub const Token = union(enum) {
    const Self = @This();

    LParen,
    RParen,
    Proposition: PropositionVar,
    Operator: WffOperator,

    /// Compare two Token instances. They are equal if they are of the same
    /// sub-type, and in the case of Proposition and Operator, if their stored
    /// values are equivalent.
    pub fn equals(self: Self, other: Self) bool {
        return switch (self) {
            .LParen => switch (other) {
                .LParen => true,
                else => false,
            },
            .RParen => switch (other) {
                .RParen => true,
                else => false,
            },
            .Proposition => |prop| switch (other) {
                .Proposition => |other_prop| prop.equals(other_prop),
                else => false,
            },
            .Operator => |op| switch (other) {
                .Operator => |other_op| op == other_op,
                else => false,
            },
        };
    }

    pub fn getString(self: *Self) []const u8 {
        return switch(self.*) {
            .LParen => "(",
            .RParen => ")",
            .Proposition => |*prop| &prop.string,
            .Operator => |op| op.getString(),
        };
    }
};

test "Token.equals" {
    var t1: Token = Token.LParen;
    var t2: Token = Token.LParen;
    var t3: Token = Token.RParen;

    var t4: Token = Token{ .Operator = WffOperator.And };
    var t5: Token = Token{ .Operator = WffOperator.And };
    var t6: Token = Token{ .Operator = WffOperator.Or };

    try std.testing.expect(t1.equals(t2));
    try std.testing.expect(!t1.equals(t3));

    try std.testing.expect(t4.equals(t5));
    try std.testing.expect(!t4.equals(t6));

    try std.testing.expect(!t1.equals(t5));
}

pub const Match = struct {
    wff_node: *ParseTree.Node,
    pattern_node: *ParseTree.Node,
};


pub const ParseTreeDepthFirstIterator = struct {
    const Self = @This();

    current: ?[*]ParseTree.Node,

    fn backtrack(self: *Self) ?[*]ParseTree.Node {
        var next_node = self.current.?;
        while (next_node[0].parent) |parent| {
            const siblings = parent.data.Nonterminal.items;
            // std.debug.print("\nnext_node: {*}\nparent_node: {*}\nsiblen-1: {*}\n", .{next_node, parent, &siblings[siblings.len - 1]});
            // for (siblings) |_, i| {
            //     std.debug.print("sibling {d}: {*}\n", .{ i, &siblings[i] });
            // }
            if (&(next_node[0]) == &(siblings[siblings.len - 1])) {
                next_node = @ptrCast(@TypeOf(next_node), parent);
            } else {
                return next_node + 1;
            }
        } else { // if we don't break above
            return null;
        }
    }

    pub fn next(self: *Self) ?*ParseTree.Node {
        const current_node = &(self.current orelse return null)[0];

        self.current = switch (current_node.data) {
            .Terminal => self.backtrack(),
            .Nonterminal => |children| @ptrCast(@TypeOf(self.current), &children.items[0]),
        };

        return current_node;
    }

    pub fn nextUnchecked(self: *Self) *ParseTree.Node {
        std.debug.assert(self.hasNext());
        return self.next().?;
    }

    pub fn peek(self: *Self) ?*ParseTree.Node {
        if (self.current) |node| {
            return &node[0];
        } else {
            return null;
        }
    }

    pub fn hasNext(self: *Self) bool {
        return self.peek() != null;
    }

    // This means we won't visit this node, its child nodes, nor their grandchildren etc.
    pub fn skipChildren(self: *Self) void {
        const current = &(self.current orelse return)[0];
        if (current.parent) |parent| {
            self.current = @ptrCast(@TypeOf(self.current), parent);
            self.current = self.backtrack();
        } else {
            self.current = null;
        }
    }
};


test "ParseTreeDepthFirstIterator" {
    var tree = try ParseTree.init(std.testing.allocator, "(p v q)");
    defer tree.deinit();

    try std.testing.expectEqual(tree.root, tree.root.data.Nonterminal.items[0].parent.?);
    var c: *ParseTree.Node = tree.root.data.Nonterminal.items[1].parent.?;
    try std.testing.expectEqual(c, c.data.Nonterminal.items[0].parent.?);

    var it = tree.root.iterDepthFirst();

    var t1 = ParseTree.Data{ .Terminal = Token.LParen };
    var t2 = ParseTree.Data{ .Terminal = Token{ .Proposition = PropositionVar{ .string = .{'p'} } } };
    var t3 = ParseTree.Data{ .Terminal = Token{ .Operator = WffOperator.Or } };
    var t4 = ParseTree.Data{ .Terminal = Token{ .Proposition = PropositionVar{ .string = .{'q'} } } };
    var t5 = ParseTree.Data{ .Terminal = Token.RParen };

    _ = it.next();
    var n = it.next().?.data;
    try std.testing.expectEqual(t1, n);
    _ = it.next();
    try std.testing.expectEqual(t2, (it.next()).?.data);
    try std.testing.expectEqual(t3, (it.next()).?.data);
    _ = it.next();
    try std.testing.expectEqual(t4, (it.next()).?.data);
    try std.testing.expectEqual(t5, (it.next()).?.data);
    try std.testing.expect((it.next()) == null);
}

pub const ParseTreePostOrderIterator = struct {
    const Self = @This();

    current: ?[*]ParseTree.Node,

    // if terminal, go to parent 
    //      if came from last child, set next=parent
    //      else, set next to next deepest sibling
    // else, get parent
    //      if parent is null, set next=null
    //      else if came from last child, set next=parent 
    //      else, set next to next deepest sibling
    pub fn next(self: *Self) ?*ParseTree.Node {
        const current_node = &(self.current orelse return null)[0];
        const parent = current_node.parent orelse {
            self.current = null;
            return current_node;
        };
        const siblings = parent.data.Nonterminal.items;

        if (current_node == &siblings[siblings.len - 1]) {
            self.current = @ptrCast(@TypeOf(self.current), parent);
            return current_node;
        }

        var next_node = &(self.current.?[1]); // get sibling node
        while (true) {
            switch(next_node.data) {
                .Terminal => break,
                .Nonterminal => |children| next_node = &children.items[0],
            }
        }
        self.current = @ptrCast(@TypeOf(self.current), next_node);

        return current_node;
    }

    pub fn nextUnchecked(self: *Self) *ParseTree.Node {
        std.debug.assert(self.hasNext());
        return self.next().?;
    }

    pub fn peek(self: *Self) ?*ParseTree.Node {
        if (self.current) |node| {
            return &node[0];
        } else {
            return null;
        }
    }

    pub fn hasNext(self: *Self) bool {
        return self.peek() != null;
    }
};

test "ParseTreePostOrderIterator" {
    var tree = try ParseTree.init(std.testing.allocator, "(p v q)");
    defer tree.deinit();

    var it = tree.root.iterPostOrder();

    var t1 = ParseTree.Data{ .Terminal = Token.LParen };
    var t2 = ParseTree.Data{ .Terminal = Token{ .Proposition = PropositionVar{ .string = .{'p'} } } };
    var t3 = ParseTree.Data{ .Terminal = Token{ .Operator = WffOperator.Or } };
    var t4 = ParseTree.Data{ .Terminal = Token{ .Proposition = PropositionVar{ .string = .{'q'} } } };
    var t5 = ParseTree.Data{ .Terminal = Token.RParen };

    try std.testing.expectEqual(t1, it.nextUnchecked().data);
    try std.testing.expectEqual(t2, it.nextUnchecked().data);
    _ = it.next();
    try std.testing.expectEqual(t3, it.nextUnchecked().data);
    try std.testing.expectEqual(t4, it.nextUnchecked().data);
    _ = it.next();
    try std.testing.expectEqual(t5, it.nextUnchecked().data);
    _ = it.next();
    try std.testing.expect(it.next() == null);
}

pub const ParseTree = struct {
    const Self = @This();

    pub const Data = union(enum) {
        Terminal: Token,
        Nonterminal: std.ArrayList(Node),
    };

    pub const Node = struct {
        parent: ?*Node = null,
        data: Data,

        pub fn copy(self: *Node, allocator: std.mem.Allocator) !*Node {
            var copy_root = try allocator.create(Node);
            copy_root.parent = null;

            var it = self.iterDepthFirst();
            var copy_it = copy_root.iterDepthFirst();

            while (it.hasNext()) {
                const node = it.nextUnchecked();
                // break if we've returned to / above the start node (we don't
                // want to copy nodes above ourselves).
                var copy_node = copy_it.peek() orelse break;

                switch (node.data) {
                    .Terminal => |tok| copy_node.data = Data{.Terminal = tok },
                    .Nonterminal => |children| {
                        copy_node.data = Data{ .Nonterminal = try std.ArrayList(Node).initCapacity(allocator, children.items.len) };
                        copy_node.data.Nonterminal.items.len = children.items.len;
                        for (copy_node.data.Nonterminal.items) |*child| {
                            child.parent = copy_node;
                        }
                    },
                }
                _ = copy_it.next();
            }

            return copy_root;
        }

        pub fn iterDepthFirst(self: *Node) ParseTreeDepthFirstIterator {
            return ParseTreeDepthFirstIterator{ .current = @ptrCast(?[*]ParseTree.Node, self) };
        }

        pub fn iterPostOrder(self: *Node) ParseTreePostOrderIterator {
            var start_node = self;
            while (true) {
                switch(start_node.data) {
                    .Terminal => break,
                    .Nonterminal => |children| start_node = &children.items[0],
                }
            }
            return ParseTreePostOrderIterator{ .current = @ptrCast(?[*]ParseTree.Node, start_node) };
        }

        pub fn equals(self: *Node, other: *Node) bool {
            var it = self.iterDepthFirst();
            var other_it = other.iterDepthFirst();

            while (it.hasNext() and other_it.hasNext()) {
                const node = it.nextUnchecked();
                const other_node = other_it.nextUnchecked();

                switch (node.data) {
                    .Terminal => |tok| switch (other_node.data) {
                        .Terminal => |other_tok| if (!tok.equals(other_tok)) return false,
                        .Nonterminal => return false,
                    },
                    .Nonterminal => switch (other_node.data) {
                        .Terminal => return false,
                        .Nonterminal => continue,
                    },
                }
            }
            return it.peek() == other_it.peek();
        }

        fn match(self: *Node, stack_allocator: std.mem.Allocator, pattern: *Node) !?std.ArrayList(Match) {
            var matches = std.ArrayList(Match).init(stack_allocator);
            errdefer matches.deinit();

            var it = self.iterDepthFirst();
            var pattern_it = pattern.iterDepthFirst();

            while (it.hasNext() and pattern_it.hasNext()) {
                const node = it.nextUnchecked();
                const pattern_node = pattern_it.nextUnchecked();

                const is_match = switch (node.data) {
                    .Terminal => |tok| switch (pattern_node.data) {
                        .Terminal => |pattern_tok| tok.equals(pattern_tok),
                        .Nonterminal => false,
                    },
                    .Nonterminal => |children| switch (pattern_node.data) {
                        .Terminal => false,
                        .Nonterminal => |pattern_children| ret: {
                            if (pattern_children.items.len == 1) {
                                try matches.append(Match{ .wff_node = node, .pattern_node = &pattern_children.items[0] });
                                it.skipChildren();
                                pattern_it.skipChildren();
                                break :ret true;
                            } else if (children.items.len == pattern_children.items.len) {
                                continue;
                            } else {
                                break :ret false;
                            }
                        },
                    },
                }; // outer switch

                if (!is_match) {
                    matches.deinit();
                    return null;
                }
            } // while
            return matches;
        }
    };

    root: *Node,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, wff_string: []const u8) !ParseTree {
        var parser = Parser.init(allocator, allocator);
        defer parser.deinit();

        return ParseTree{ .root = try parser.parse(wff_string), .allocator = allocator};
    }

    pub fn deinit(self: *Self) void {
        var it = self.iterPostOrder();
        while (it.next()) |node| {
            const n = node;
            switch (n.data) {
                .Terminal => {},
                .Nonterminal => |children| children.deinit(),
            }
        }
        self.allocator.destroy(self.root);
    }

    pub fn copy(self: *Self) !ParseTree {
        return ParseTree{.root = try self.root.copy(self.allocator), .allocator = self.allocator};
    }

    /// Compare two ParseTree instances. They are equal if both have the same
    /// tree structure (determined by non-terminal nodes, which are the only
    /// nodes with children) and if each pair of corresponding terminal nodes
    /// have equivalent tokens (see Token.equals).
    pub fn equals(self: *Self, other: *Self) bool {
        return self.root.equals(other.root);
    }

    pub fn iterDepthFirst(self: *Self) ParseTreeDepthFirstIterator {
        return self.root.iterDepthFirst();
    }

    pub fn iterPostOrder(self: *Self) ParseTreePostOrderIterator {
        return self.root.iterPostOrder();
    }

    pub fn toString(self: *Self, allocator: std.mem.Allocator) ![]u8 {
        var string_buf = std.ArrayList(u8).init(allocator);
        errdefer string_buf.deinit();

        var it = self.iterDepthFirst();
        while (it.next()) |node| {
            switch(node.data) {
                .Terminal => |*tok| try string_buf.appendSlice(tok.getString()),
                .Nonterminal => {},
            }
        }
        return string_buf.toOwnedSlice();
    }

    // !!!!!!!!!!!
    // TODO: Idea: .equals returns an iterator of pairs if equal, then we just
    // iterate over those pairs. We can then make assumptions that make this
    // matching simpler, since we know the trees are equal.
    /// Similar to ParseTree.equals, but in addition to checking the equality
    /// of the trees, we also record "matches". A match consists of a pointer
    /// to a proposition node in a pattern/template tree, and a pointer to a
    /// corresponding proposition or non-terminal (wff) in self.
    /// Assumes both parse trees are valid.
    /// Returns a list of match lists (ArrayList(ArrayList(Match))) if the trees
    /// are equal, else null.
    pub fn matchAll(self: *Self, pattern: *Self) !?std.ArrayList(std.ArrayList(Match)) {
        var all_matches = std.ArrayList(std.ArrayList(Match)).init(self.allocator);
        errdefer {
            for (all_matches.items) |matches| {
                matches.deinit();
            }
            all_matches.deinit();
        }

        var it = self.iterDepthFirst();
        var pattern_it = pattern.iterDepthFirst();

        while (it.hasNext() and pattern_it.hasNext()) {
            const node = it.nextUnchecked();
            const pattern_node = pattern_it.nextUnchecked();

            const is_match = switch (node.data) {
                .Terminal => |tok| switch (pattern_node.data) {
                    .Terminal => |pattern_tok| tok.equals(pattern_tok),
                    .Nonterminal => false,
                },
                .Nonterminal => switch (pattern_node.data) {
                    .Terminal => false,
                    .Nonterminal => ret: {
                        if (try node.match(self.allocator, pattern_node)) |matches| {
                            try all_matches.append(matches);
                            it.skipChildren();
                            pattern_it.skipChildren();
                            break :ret true;
                        } else {
                            continue;
                        }
                    },
                },
            };

            if (!is_match) {
                for (all_matches.items) |matches| {
                    matches.deinit();
                }
                all_matches.deinit();
                return null;
            }
        }
        if (all_matches.items.len > 0) {
            return all_matches;
        } else {
            all_matches.deinit();
            return null;
        }
    }
};

// TODO: fn to build trees more easily for testing larger expressions

test "ParseTree: ''" {
    try std.testing.expectError(ParseError.NoTokensFound, ParseTree.init(std.testing.allocator, ""));
}

test "ParseTree: '~)q p v('" {
    try std.testing.expectError(ParseError.InvalidSyntax, ParseTree.init(std.testing.allocator, "~)q p v ("));
}

test "ParseTree: '(p v q)'" {
    var allocator = std.testing.allocator;
    var tree = try ParseTree.init(allocator, "(p v q)");
    defer tree.deinit();

    // Build the expected tree manually... it's pretty messy
    var wff1: ParseTree.Node = undefined;
    var wff2: ParseTree.Node = undefined;
    var root: ParseTree.Node = undefined;

    var children1 = try std.ArrayList(ParseTree.Node).initCapacity(allocator, 1);
    defer children1.deinit();
    var children2 = try std.ArrayList(ParseTree.Node).initCapacity(allocator, 1);
    defer children2.deinit();
    var root_children = try std.ArrayList(ParseTree.Node).initCapacity(allocator, 5);
    root_children.items.len = 5;
    defer root_children.deinit();
    
    var t1 = ParseTree.Node{ .parent = &root, .data = ParseTree.Data{ .Terminal = Token.LParen } };
    var t2 = ParseTree.Node{ .parent = &(root_children.items[1]), .data = ParseTree.Data{ .Terminal = Token{ .Proposition = PropositionVar{ .string = .{'p'} } } } };
    var t3 = ParseTree.Node{ .parent = &root, .data = ParseTree.Data{ .Terminal = Token{ .Operator = WffOperator.Or } } };
    var t4 = ParseTree.Node{ .parent = &(root_children.items[3]), .data = ParseTree.Data{ .Terminal = Token{ .Proposition = PropositionVar{ .string = .{'q'} } } } };
    var t5 = ParseTree.Node{ .parent = &root, .data = ParseTree.Data{ .Terminal = Token.RParen } };

    try children1.append(t2);
    wff1 = ParseTree.Node{ .parent = &root, .data = ParseTree.Data{ .Nonterminal = children1 } };

    try children2.append(t4);
    wff2 = ParseTree.Node{ .parent = &root, .data = ParseTree.Data{ .Nonterminal = children2 } };

    root_children.items[0] = t1;
    root_children.items[1] = wff1;
    root_children.items[2] = t3;
    root_children.items[3] = wff2;
    root_children.items[4] = t5;
    root = ParseTree.Node{ .data = ParseTree.Data{ .Nonterminal = root_children } };

    // Hardcoded equality test of tree
    try std.testing.expectEqual(t1.data, tree.root.data.Nonterminal.items[0].data);
    try std.testing.expectEqual(t2.data, tree.root.data.Nonterminal.items[1].data.Nonterminal.items[0].data);
    try std.testing.expectEqual(t3.data, tree.root.data.Nonterminal.items[2].data);
    try std.testing.expectEqual(t4.data, tree.root.data.Nonterminal.items[3].data.Nonterminal.items[0].data);
    try std.testing.expectEqual(t5.data, tree.root.data.Nonterminal.items[4].data);

    // Function equality test of tree
    try std.testing.expect(tree.root.equals(&root));
}

test "ParseTree.toString: (p v q)" {
    var tree = try ParseTree.init(std.testing.allocator, "(p v q)");
    defer tree.deinit();

    var string = try tree.toString(std.testing.allocator);
    defer std.testing.allocator.free(string);

    try std.testing.expectEqualStrings("(pvq)", string);
}

test "ParseTree.toString: ~((a ^ b) => (c ^ ~d))" {
    var tree = try ParseTree.init(std.testing.allocator, "~((a ^ b) => (c ^ ~d))");
    defer tree.deinit();

    var string = try tree.toString(std.testing.allocator);
    defer std.testing.allocator.free(string);

    try std.testing.expectEqualStrings("~((a^b)=>(c^~d))", string);
}

test "ParseTree.copy: (p v q)" {
    var allocator = std.testing.allocator;
    var tree = try ParseTree.init(allocator, "(p v q)");
    defer tree.deinit();
    var copy = try tree.copy();
    defer copy.deinit();

    try std.testing.expect(tree.equals(&copy));
}

test "ParseTree.copy: ((a ^ b) v (c ^ d))" {
    var allocator = std.testing.allocator;
    var tree = try ParseTree.init(allocator, "((a ^ b) v (c ^ d))");
    defer tree.deinit();
    var copy = try tree.copy();
    defer copy.deinit();

    try std.testing.expect(tree.equals(&copy));
}

test "ParseTree.Node.match: (p v q)" {
    var allocator = std.testing.allocator;
    var tree = try ParseTree.init(allocator, "(p v q)");
    defer tree.deinit();
    var pattern = try ParseTree.init(allocator, "(p v q)");
    defer pattern.deinit();

    const matches = try tree.root.match(allocator, pattern.root) orelse return ParseError.MatchError;
    defer matches.deinit();

    const expected = [_]Match{
        Match{
            .wff_node = &tree.root.data.Nonterminal.items[1],
            .pattern_node = &pattern.root.data.Nonterminal.items[1].data.Nonterminal.items[0],
        },
        Match{
            .wff_node = &tree.root.data.Nonterminal.items[3],
            .pattern_node = &pattern.root.data.Nonterminal.items[3].data.Nonterminal.items[0],
        },
    };

    try std.testing.expectEqualSlices(Match, &expected, matches.items);
}

test "ParseTree.Node.match: ((a ^ b) v (c ^ d))" {
    var allocator = std.testing.allocator;
    var tree = try ParseTree.init(allocator, "((a ^ b) v (c ^ d))");
    defer tree.deinit();
    var pattern = try ParseTree.init(allocator, "(p v q)");
    defer pattern.deinit();

    const matches = try tree.root.match(allocator, pattern.root) orelse return ParseError.MatchError;
    defer matches.deinit();

    const expected = [_]Match{
        Match{
            .wff_node = &tree.root.data.Nonterminal.items[1],
            .pattern_node = &pattern.root.data.Nonterminal.items[1].data.Nonterminal.items[0],
        },
        Match{
            .wff_node = &tree.root.data.Nonterminal.items[3],
            .pattern_node = &pattern.root.data.Nonterminal.items[3].data.Nonterminal.items[0],
        },
    };

    try std.testing.expectEqualSlices(Match, &expected, matches.items);
}

test "ParseTree.matchAll: (p v q)" {
    var allocator = std.testing.allocator;
    var tree = try ParseTree.init(allocator, "(p v q)");
    defer tree.deinit();
    var pattern = try ParseTree.init(allocator, "(p v q)");
    defer pattern.deinit();

    var all_matches = try tree.matchAll(&pattern);
    defer {
        if (all_matches) |all| {
            for (all.items) |matches| {
                matches.deinit();
            }
            all.deinit();
        }
    }

    try std.testing.expect(all_matches.?.items.len == 1);

    var match1 = all_matches.?.items[0];

    const expected = [_]Match{
        Match{
            .wff_node = &tree.root.data.Nonterminal.items[1],
            .pattern_node = &pattern.root.data.Nonterminal.items[1].data.Nonterminal.items[0],
        },
        Match{
            .wff_node = &tree.root.data.Nonterminal.items[3],
            .pattern_node = &pattern.root.data.Nonterminal.items[3].data.Nonterminal.items[0],
        },
    };

    try std.testing.expectEqualSlices(Match, &expected, match1.items);
}

// Tokenize a string containing a WFF. Returns an ArrayList of Tokens if a valid
// string is passed, else a ParseError. Caller must free the returned ArrayList.
fn tokenize(allocator: std.mem.Allocator, wff_string: []const u8) !std.ArrayList(Token) {
    const State = enum {
        None,
        Cond,
        BicondBegin,
        BicondEnd,
    };

    var tokens = std.ArrayList(Token).init(allocator);

    var state: State = State.None;
    for (wff_string) |c| {
        errdefer {
            debug.print("\n\tInvalid token: {c}\n\tProcessed tokens: {any}\n", .{ c, tokens.items });
            tokens.deinit();
        }

        if (std.ascii.isWhitespace(c)) {
            continue;
        }

        // This is the main tokenizing logic. There are 3 outcomes of this
        // block:
        // (1) A token is correctly processed => a Token struct is assigned to
        //     tok, code flow continues normally
        // (2) An intermediate token is processed (e.g. '=' in the "<=>"
        //     operator) => state is changed appropriately (e.g. to BicondEnd)
        //     and we continue right away to the next loop iteration without
        //     assigning a value to tok.
        // (3) An unexpected token is encountered => we return an error.
        var tok = try switch (state) {
            .None => switch (c) {
                '~' => Token{ .Operator = WffOperator.Not },
                'v' => Token{ .Operator = WffOperator.Or },
                '^' => Token{ .Operator = WffOperator.And },
                '=' => {
                    state = State.Cond;
                    continue;
                },
                '<' => {
                    state = State.BicondBegin;
                    continue;
                },

                '(' => Token.LParen,
                ')' => Token.RParen,

                // TODO: Include v as an allowable variable name (currently it
                // conflicts with OR operator).
                'a'...'u', 'w'...'z', 'A'...'Z' => |val| Token{ .Proposition = PropositionVar{ .string = .{val} } },
    

                else => ParseError.UnexpectedToken,
            },
            .Cond => switch (c) {
                '>' => ret: {
                    state = State.None;
                    break :ret Token{ .Operator = WffOperator.Cond };
                },
                else => ParseError.UnexpectedToken,
            },
            .BicondBegin => switch (c) {
                '=' => {
                    state = State.BicondEnd;
                    continue;
                },
                else => ParseError.UnexpectedToken,
            },
            .BicondEnd => switch (c) {
                '>' => ret: {
                    state = State.None;
                    break :ret Token{ .Operator = WffOperator.Bicond };
                },
                else => ParseError.UnexpectedToken,
            },
        };

        try tokens.append(tok);
    }
    if (tokens.items.len == 0) {
        return ParseError.NoTokensFound;
    }
    return tokens;
}

test "tokenize: '(p v q)'" {
    var result = try tokenize(std.testing.allocator, "(p v q)");
    defer result.deinit();
    const expected = [_]Token{
        Token.LParen,
        Token{ .Proposition = PropositionVar{ .string = .{'p'} } },
        Token{ .Operator = WffOperator.Or },
        Token{ .Proposition = PropositionVar{ .string = .{'q'} } },
        Token.RParen,
    };

    try std.testing.expectEqualSlices(Token, &expected, result.items);
}

test "tokenize: ''" {
    try std.testing.expectError(ParseError.NoTokensFound, tokenize(std.testing.allocator, ""));
}

test "tokenize: 'p'" {
    var result = try tokenize(std.testing.allocator, "p");
    defer result.deinit();
    const expected = [_]Token{
        Token{ .Proposition = PropositionVar{ .string = .{'p'} } },
    };

    try std.testing.expectEqualSlices(Token, &expected, result.items);
}

test "tokenize: p & q" {
    try std.testing.expectError(ParseError.UnexpectedToken, tokenize(std.testing.allocator, "p & q"));
}

/// Shift-Reduce parser for parsing WFF's.
/// Based on these grammar rules:
/// R1: S   -> wff
/// R2: wff -> Proposition
/// R3: wff -> Not    wff
/// R4: wff -> LParen wff And    wff RParen
/// R5: wff -> LParen wff Or     wff RParen
/// R6: wff -> LParen wff Cond   wff RParen
/// R7: wff -> LParen wff Bicond wff RParen
const Parser = struct {
    const Self = @This();

    const Rule = enum {
        // R1: S -> wff  (we don't need this rule in practice)
        R2, // wff -> Proposition
        R3, // wff -> Not    wff
        R4, // wff -> LParen wff And    wff RParen
        R5, // wff -> LParen wff Or     wff RParen
        R6, // wff -> LParen wff Cond   wff RParen
        R7, // wff -> LParen wff Bicond wff RParen
    };

    const StackSymbol = enum {
        Wff,
        Proposition,
        Not,
        LParen,
        RParen,
        And,
        Or,
        Cond,
        Bicond,
    };

    const State = enum {
        S1,
        S2,
        S3,
        S4,
        S5,
        S6,
        S7,
        S8,
        S9,
        S10,
        S11,
        S12,
        S13,
        S14,
        S15,
        S16,
        S17,
        S18,
        S19,
    };

    const StackItem = struct {
        state: State,
        node: ParseTree.Node,
    };

    stack: std.ArrayList(StackItem),
    stack_allocator: std.mem.Allocator,
    tree_allocator: std.mem.Allocator,

    pub fn init(stack_allocator: std.mem.Allocator, tree_allocator: std.mem.Allocator) Self {
        return Self{
            .stack = std.ArrayList(StackItem).init(stack_allocator),
            .stack_allocator = stack_allocator,
            .tree_allocator = tree_allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.stack.deinit();
    }

    fn shift_terminal(state: State, symbol: StackSymbol) !State {
        return switch (state) {
            .S1, .S3, .S5, .S7, .S8, .S9, .S10 => switch (symbol) {
                .Proposition => .S4,
                .Not => .S3,
                .LParen => .S5,
                else => ParseError.InvalidSyntax,
            },
            .S6 => switch (symbol) {
                .And => .S7,
                .Or => .S8,
                .Cond => .S9,
                .Bicond => .S10,
                else => ParseError.InvalidSyntax,
            },
            .S11 => switch (symbol) {
                .RParen => .S12,
                else => ParseError.InvalidSyntax,
            },
            .S13 => switch (symbol) {
                .RParen => .S14,
                else => ParseError.InvalidSyntax,
            },
            .S15 => switch (symbol) {
                .RParen => .S16,
                else => ParseError.InvalidSyntax,
            },
            .S17 => switch (symbol) {
                .RParen => .S18,
                else => ParseError.InvalidSyntax,
            },
            else => ParseError.InvalidSyntax,
        };
    }

    fn shift_nonterminal(state: State, symbol: StackSymbol) !State {
        return switch (symbol) {
            .Wff => switch (state) {
                .S1 => .S2,
                .S3 => .S19,
                .S5 => .S6,
                .S7 => .S11,
                .S8 => .S13,
                .S9 => .S15,
                .S10 => .S17,
                else => ParseError.InvalidSyntax,
            },
            else => ParseError.InvalidSyntax,
        };
    }

    fn reduce(self: *Self, state: State) !?State {
        const rule = switch (state) {
            .S4 => Rule.R2,
            .S12 => Rule.R4,
            .S14 => Rule.R5,
            .S16 => Rule.R6,
            .S18 => Rule.R7,
            .S19 => Rule.R3,
            else => return null,
        };

        const child_count: usize = switch (rule) {
            .R2 => 1,
            .R3 => 2,
            .R4, .R5, .R6, .R7 => 5,
        };

        var children = try std.ArrayList(ParseTree.Node).initCapacity(self.tree_allocator, child_count);
        children.items.len = child_count; // manually set len so we can insert in correct order
        var i: usize = 1;
        while (i <= child_count) : (i += 1) {
            var child = self.stack.pop().node;
            children.items[children.items.len - i] = child;
            switch (child.data) {
                .Nonterminal => |grandchildren| {
                    for (grandchildren.items) |*grandchild| {
                        grandchild.parent = &(children.items[children.items.len - i]);
                    }
                },
                .Terminal => {},
            }
        }
        //std.mem.reverse(ParseTree.Node, children.items[0..child_count]);

        const new_parent = ParseTree.Node{ .data = ParseTree.Data{ .Nonterminal = children } };

        const new_top_state = self.stack.items[self.stack.items.len - 1].state;
        const reduced_state = try shift_nonterminal(new_top_state, StackSymbol.Wff);

        try self.stack.append(StackItem{ .state = reduced_state, .node = new_parent });
        return reduced_state;
    }

    fn parse(self: *Self, wff_string: []const u8) !*ParseTree.Node {
        // Tokenize given string
        var tokens = try tokenize(self.stack_allocator, wff_string);
        defer tokens.deinit();

        // Initialize parsing stack
        try self.stack.append(StackItem{ .state = .S1, .node = undefined }); // Initial state is S1

        // Parse tokens
        for (tokens.items) |token| {
            const top_state = self.stack.items[self.stack.items.len - 1].state;

            const stack_symbol = switch (token) {
                .LParen => StackSymbol.LParen,
                .RParen => StackSymbol.RParen,
                .Operator => |op| switch (op) {
                    .And => StackSymbol.And,
                    .Or => StackSymbol.Or,
                    .Not => StackSymbol.Not,
                    .Cond => StackSymbol.Cond,
                    .Bicond => StackSymbol.Bicond,
                },
                .Proposition => StackSymbol.Proposition,
            };

            var new_state = try shift_terminal(top_state, stack_symbol);
            const new_node = ParseTree.Node{ .data = ParseTree.Data{ .Terminal = token } };
            try self.stack.append(StackItem{ .state = new_state, .node = new_node });

            while (try self.reduce(new_state)) |result_state| {
                new_state = result_state;
            }
        }
        var root = try self.tree_allocator.create(ParseTree.Node);
        root.* = self.stack.pop().node;
        for (root.data.Nonterminal.items) |*child| {
            child.parent = root;
        }
        return root;
    }
};

test "Parse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(), arena.allocator());
    _ = try parser.parse("(p v q)");
}