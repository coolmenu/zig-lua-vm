const std = @import("std");

// -----------------------------------------------------------------------------
// NOTE: This is a teaching-oriented VM.
// It intentionally focuses on a tiny subset of Lua so the closure/upvalue path
// stays readable. When you look for the "real" behaviour always keep in mind:
// - everything lives in a single file
// - the call/return convention is drastically simplified
// - GC only keeps the objects we allocate in this demo
// Read the sections in order if you are new, or jump directly to the
// "闭包与 Upvalue 核心逻辑" header if you only care about capture/close.
// -----------------------------------------------------------------------------

// ============================================================================
// GC 对象定义
// ============================================================================
const ObjType = enum {
    String,
    Proto,
    Closure,
    Upvalue,
};

const GCObject = struct {
    next: ?*GCObject,
    obj_type: ObjType,
    marked: bool,
};

const ObjString = struct {
    header: GCObject,
    bytes: []u8,
};

// 描述 Upvalue 来源
const UpvalueLoc = struct {
    is_local: bool, // true: 从父栈帧捕获; false: 从父闭包的 upvalues 捕获
    index: u8, // 索引
};

// 函数原型 (Compile-time info)
const ObjProto = struct {
    header: GCObject,
    code: []const Instruction,
    constants: []const LuaValue,
    upvalues: []const UpvalueLoc,
    protos: []const *ObjProto = &[_]*ObjProto{}, // [NEW] 子函数原型
    // 调试信息等可在此扩展
};

// 上值 (Runtime capture)
const ObjUpvalue = struct {
    header: GCObject,
    location: *LuaValue, // 指向栈上值(Open) 或 closed_value(Closed)
    closed_value: LuaValue,
    next_open: ?*ObjUpvalue, // 链表：用于 Open Upvalues
};

// 闭包 (Runtime function instance)
const ObjClosure = struct {
    header: GCObject,
    proto: *ObjProto,
    upvalues: []?*ObjUpvalue, // 指针数组 (Optional for initialization safety)
};

// ============================================================================
// Lua 值类型定义
// ============================================================================
const LuaValue = union(enum) {
    Nil: void,
    Boolean: bool,
    Number: f64,
    Integer: i64,
    String: *ObjString,
    Closure: *ObjClosure,

    pub fn format(
        self: LuaValue,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        switch (self) {
            .Nil => try writer.writeAll("nil"),
            .Boolean => |b| try writer.print("{}", .{b}),
            .Number => |n| try writer.print("{d}", .{n}),
            .Integer => |i| try writer.print("{}", .{i}),
            .String => |s| try writer.print("\"{s}\"", .{s.bytes}),
            .Closure => |c| try writer.print("<closure 0x{x}>", .{@intFromPtr(c)}),
        }
    }
};

// ============================================================================
// Lua 指令集定义
// ============================================================================
const Opcode = enum(u8) {
    MOVE = 0,
    LOADK = 1,
    ADD = 2,
    SUB = 3,
    MUL = 4,
    JMP = 5,
    EQ = 6,
    CALL = 7,
    RETURN = 8,
    CLOSURE = 9, // [NEW] 创建闭包
    GETUPVAL = 10, // [NEW] 读 Upvalue
    SETUPVAL = 11, // [NEW] 写 Upvalue
    CLOSE = 12, // [NEW] 显式关闭 Upvalue (通常由 RETURN 隐式处理，但也可能用于 block end)
};

const Instruction = packed struct {
    opcode: u8,
    a: u8,
    b: u8,
    c: u8,

    pub fn init(op: Opcode, a: u8, b: u8, c: u8) Instruction {
        return .{
            .opcode = @intFromEnum(op),
            .a = a,
            .b = b,
            .c = c,
        };
    }

    pub fn getOpcode(self: Instruction) Opcode {
        return @enumFromInt(self.opcode);
    }

    pub fn getBx(self: Instruction) u16 {
        return (@as(u16, self.b) << 8) | @as(u16, self.c);
    }

    pub fn getSBx(self: Instruction) i16 {
        return @as(i16, @bitCast(self.getBx())) - 0x7FFF;
    }
};

// ============================================================================
// 虚拟机核心结构
// ============================================================================
const initial_gc_threshold: usize = 64;
const STACK_MAX = 1024;
const FRAMES_MAX = 64;

const CallFrame = struct {
    closure: *ObjClosure,
    ip: usize,
    slots: usize, // 该帧在 stack 中的起始偏移量 (= R[0] 的真实位置)
};

const VM = struct {
    allocator: std.mem.Allocator,

    stack: [STACK_MAX]LuaValue,
    stack_top: usize, // 指向栈顶下一个空闲位置

    frames: [FRAMES_MAX]CallFrame,
    frame_count: usize,

    open_upvalues: ?*ObjUpvalue, // Open Upvalues 链表头
    objects: ?*GCObject, // GC 对象链表头

    bytes_allocated: usize,
    next_gc_threshold: usize,

    pub fn init(allocator: std.mem.Allocator) VM {
        var vm = VM{
            .allocator = allocator,
            .stack = undefined,
            .stack_top = 0,
            .frames = undefined,
            .frame_count = 0,
            .open_upvalues = null,
            .objects = null,
            .bytes_allocated = 0,
            .next_gc_threshold = initial_gc_threshold,
        };
        // 初始化栈
        for (&vm.stack) |*v| v.* = LuaValue{ .Nil = {} };
        return vm;
    }

    pub fn deinit(self: *VM) void {
        self.freeAllObjects();
    }

    // 辅助：压栈
    fn push(self: *VM, value: LuaValue) void {
        self.stack[self.stack_top] = value;
        self.stack_top += 1;
    }

    // 辅助：弹栈
    fn pop(self: *VM) LuaValue {
        self.stack_top -= 1;
        return self.stack[self.stack_top];
    }

    // 核心：解释执行
    pub fn execute(self: *VM, closure: *ObjClosure) !void {
        // 准备初始栈帧：把闭包放到 stack[0]，并创建 frame[0]
        self.push(LuaValue{ .Closure = closure }); // slot 0: main function
        self.frames[0] = CallFrame{
            .closure = closure,
            .ip = 0,
            .slots = 0,
        };
        self.frame_count = 1;

        while (self.frame_count > 0) {
            // 获取当前帧
            var frame = &self.frames[self.frame_count - 1];
            const inst = frame.closure.proto.code[frame.ip];
            frame.ip += 1; // Advance IP

            const op = inst.getOpcode();

            // 调试打印
            // std.debug.print("IP={d:3} | {s:8} A={d} B={d} C={d}\n", .{
            //     frame.ip - 1, @tagName(op), inst.a, inst.b, inst.c,
            // });

            switch (op) {
                .MOVE => {
                    const val = self.stack[frame.slots + inst.b];
                    self.stack[frame.slots + inst.a] = val;
                },
                .LOADK => {
                    const bx = inst.getBx();
                    const val = frame.closure.proto.constants[bx];
                    self.stack[frame.slots + inst.a] = val;
                },
                .ADD, .SUB, .MUL => try self.execBinaryOp(inst, frame, op),
                .JMP => {
                    const offset = inst.getSBx();
                    frame.ip = @intCast(@as(i32, @intCast(frame.ip)) + offset);
                },
                .EQ => {
                    const a = self.stack[frame.slots + inst.a];
                    const b = self.stack[frame.slots + inst.b];
                    if (self.valuesEqual(a, b)) {
                        frame.ip += 1;
                    }
                },
                .CALL => {
                    // CALL A B C
                    // A: 函数在栈上的位置
                    // B: 参数个数 + 1 (0代表不定)
                    // C: 返回值个数 + 1
                    // 简化：这里只实现"0参数 + 最多1个返回值"的情形。
                    // 这让我们可以专注在 Upvalue 逻辑上，不被 Lua 真正的
                    // CALL 细节分心。

                    const func_slot = frame.slots + inst.a;
                    const func_val = self.stack[func_slot];

                    switch (func_val) {
                        .Closure => |callee| {
                            // Push new frame
                            if (self.frame_count >= FRAMES_MAX) return error.StackOverflow;

                            self.frames[self.frame_count] = CallFrame{
                                .closure = callee,
                                .ip = 0,
                                .slots = func_slot + 1, // 参数从 func + 1 开始
                            };
                            self.frame_count += 1;
                            // [FIX] Ensure stack_top is above the new frame's registers
                            // In a real VM, Proto would have max_stack_size. Here we assume 16.
                            const needed_top = func_slot + 1 + 16;
                            if (self.stack_top < needed_top) {
                                self.stack_top = needed_top;
                            }
                        },
                        else => return error.NotCallable,
                    }
                },
                .RETURN => {
                    // RETURN A B
                    // A: 返回值起始位置
                    // B: 返回值个数 + 1

                    const result_start = frame.slots + inst.a;
                    std.debug.print("RETURN: {any}\n", .{self.stack[result_start]});

                    // 1. 关闭当前函数的所有 Upvalues
                    self.closeUpvalues(&self.stack[frame.slots]);

                    // 2. 弹出栈帧
                    self.frame_count -= 1;

                    if (self.frame_count == 0) {
                        // 虚拟机结束
                        return;
                    }

                    // 3. 处理返回值 (简化：只处理1个返回值)
                    // 实际上应该把返回值 copy 到 caller 的栈顶
                    // const caller_frame = &self.frames[self.frame_count - 1];
                    // 假设 caller 期望返回值放在它的栈顶 (简化处理，暂不严谨)
                    // 简单实现：如果 B=2 (1个返回值)，把它放到 caller 的某个寄存器？
                    // 标准 Lua RETURN 会把结果移动到 CALL指令指定的位置。
                    // 这里简化：不做移动，假设调用者自己去栈顶拿，或者我们暂不处理返回值传递。
                    // 修正：为了让 Counter 例子跑通，我们需要返回值。
                    // 假设 CALL A 1 2 (期望1个返回值到 A)
                    // 那么 RETURN A 2 (返回 A 位置的1个值)
                    // 我们需要把 result_start 的值 复制到 caller 的 func_slot 位置

                    // 这里的逻辑比较复杂，为了 Demo 简单，我们假设返回值直接覆盖 caller 的 A 寄存器
                    // 但我们需要知道 caller 的 A 是哪里。
                    // 实际上 CALL 指令执行时，caller 的 ip 还没动（或者刚动）。
                    // 真正的 Lua VM 会在 CALL 指令里记录期望返回值位置，或者 RETURN 只是把值放到栈顶，由 caller 之后的指令处理。
                    // 让我们采用最简方案：RETURN 把值放到 stack[frame.slots - 1] (即函数对象本身的位置)，
                    // 这样 caller 就可以在那个位置读到返回值。

                    if (inst.b == 2) { // 返回 1 个值
                        const ret_val = self.stack[result_start];
                        self.stack[frame.slots - 1] = ret_val; // 覆盖函数对象
                    }
                },
                .CLOSURE => {
                    // CLOSURE A Bx
                    // A: 目标寄存器
                    // Bx: Proto 索引 (在 protos 数组里)

                    const bx = inst.getBx();
                    const sub_proto = frame.closure.proto.protos[bx];
                    const new_closure = try self.newClosure(sub_proto);
                    // Push to stack to protect from GC
                    self.push(LuaValue{ .Closure = new_closure });

                    // 处理 Upvalues
                    for (sub_proto.upvalues, 0..) |up_loc, i| {
                        if (up_loc.is_local) {
                            // 捕获当前栈帧的局部变量
                            const slot_ptr = &self.stack[frame.slots + up_loc.index];
                            new_closure.upvalues[i] = try self.captureUpvalue(slot_ptr);
                        } else {
                            // 捕获当前闭包的 Upvalue
                            // 注意：frame.closure.upvalues[index] 可能是 null?
                            // 运行时应该是 valid 的。
                            new_closure.upvalues[i] = frame.closure.upvalues[up_loc.index].?;
                        }
                    }

                    _ = self.pop(); // Pop protection
                    self.stack[frame.slots + inst.a] = LuaValue{ .Closure = new_closure };
                },
                .GETUPVAL => {
                    // GETUPVAL A B
                    // R[A] = UpValue[B]
                    const val = frame.closure.upvalues[inst.b].?.location.*;
                    self.stack[frame.slots + inst.a] = val;
                },
                .SETUPVAL => {
                    // SETUPVAL A B
                    // UpValue[B] = R[A]
                    const val = self.stack[frame.slots + inst.a];
                    frame.closure.upvalues[inst.b].?.location.* = val;
                },
                .CLOSE => {
                    // CLOSE A
                    // Close upvalues >= R[A]
                    const slot_ptr = &self.stack[frame.slots + inst.a];
                    self.closeUpvalues(slot_ptr);
                },
            }
        }
    }

    fn execBinaryOp(self: *VM, inst: Instruction, frame: *CallFrame, op: Opcode) !void {
        const b = self.stack[frame.slots + inst.b];
        const c = self.stack[frame.slots + inst.c];

        // 简化：只处理 Integer/Number
        const res = switch (b) {
            .Integer => |bi| switch (c) {
                .Integer => |ci| switch (op) {
                    .ADD => LuaValue{ .Integer = bi + ci },
                    .SUB => LuaValue{ .Integer = bi - ci },
                    .MUL => LuaValue{ .Integer = bi * ci },
                    else => unreachable,
                },
                else => return error.TypeError,
            },
            else => return error.TypeError,
        };
        self.stack[frame.slots + inst.a] = res;
    }

    fn valuesEqual(self: *VM, a: LuaValue, b: LuaValue) bool {
        _ = self;
        return switch (a) {
            .Integer => |av| switch (b) {
                .Integer => |bv| av == bv,
                else => false,
            },
            else => false, // 简化
        };
    }

    // ========================================================================
    // 闭包与 Upvalue 核心逻辑
    // ========================================================================

    fn newClosure(self: *VM, proto: *ObjProto) !*ObjClosure {
        self.maybeCollectGarbage();
        const closure = try self.allocator.create(ObjClosure);
        closure.header = GCObject{ .next = self.objects, .obj_type = .Closure, .marked = false };
        self.objects = &closure.header;

        closure.proto = proto;
        closure.upvalues = try self.allocator.alloc(?*ObjUpvalue, proto.upvalues.len);
        for (closure.upvalues) |*u| u.* = null; // Init to null

        self.bytes_allocated += @sizeOf(ObjClosure) + (@sizeOf(?*ObjUpvalue) * proto.upvalues.len);
        return closure;
    }

    fn captureUpvalue(self: *VM, local_ptr: *LuaValue) !*ObjUpvalue {
        // STEP 1: 在 open_upvalues 链表中查找，看看是否已有闭包捕获了
        //         同一个栈槽。如果有，则直接复用，实现多个闭包共享。
        var prev: ?*ObjUpvalue = null;
        var current = self.open_upvalues;

        while (current) |upval| {
            if (upval.location == local_ptr) {
                return upval; // 找到了！复用
            }
            if (@intFromPtr(upval.location) < @intFromPtr(local_ptr)) {
                // 链表是按栈地址从高到低排的？还是低到高？
                // Lua 官方是按栈顺序排的。
                // 这里简化：不排序，直接遍历到底。
            }
            prev = upval;
            current = upval.next_open;
        }

        // STEP 2: 没找到，新建一个 Upvalue 对象，并插入链表头
        self.maybeCollectGarbage();
        const upval = try self.allocator.create(ObjUpvalue);
        upval.header = GCObject{ .next = self.objects, .obj_type = .Upvalue, .marked = false };
        self.objects = &upval.header;

        upval.location = local_ptr; // 指向栈
        upval.closed_value = LuaValue{ .Nil = {} };
        upval.next_open = self.open_upvalues; // 插入表头
        self.open_upvalues = upval;

        self.bytes_allocated += @sizeOf(ObjUpvalue);
        return upval;
    }

    fn closeUpvalues(self: *VM, last_slot_ptr: *LuaValue) void {
        var current = self.open_upvalues;
        var prev: ?*ObjUpvalue = null;

        while (current) |upval| {
            // 如果 upval 指向的地址 >= last_slot_ptr，说明它在即将销毁的栈帧里
            // （这个判断依赖"栈向高地址增长"的约定；在这个 toy VM 里成立）
            if (@intFromPtr(upval.location) >= @intFromPtr(last_slot_ptr)) {
                // Close it!
                upval.closed_value = upval.location.*;
                upval.location = &upval.closed_value;

                // Remove from open list：close 后它不再属于 open 链表，
                // 但闭包数组里仍然持有这个 ObjUpvalue 的指针。
                const next = upval.next_open;
                if (prev) |p| {
                    p.next_open = next;
                } else {
                    self.open_upvalues = next;
                }
                current = next;
            } else {
                prev = upval;
                current = upval.next_open;
            }
        }
    }

    // ========================================================================
    // GC 实现
    // ========================================================================

    fn maybeCollectGarbage(self: *VM) void {
        if (self.bytes_allocated >= self.next_gc_threshold) {
            self.collectGarbage();
        }
    }

    pub fn collectGarbage(self: *VM) void {
        std.debug.print("[GC] Start...\n", .{});
        self.markRoots();
        self.sweep();
        self.next_gc_threshold = @max(self.bytes_allocated * 2, initial_gc_threshold);
        std.debug.print("[GC] Done. Allocated: {d}\n", .{self.bytes_allocated});
    }

    fn markRoots(self: *VM) void {
        // 1. Stack
        for (self.stack[0..self.stack_top]) |val| {
            self.markValue(val);
        }
        // 2. Open Upvalues (其实不用显式标，因为它们指向 Stack，Stack 标了就行？
        // 不，Upvalue 对象本身在 Heap 上，需要被标。
        // 但是 Upvalue.location 指向 Stack，不需要顺着 location 标。
        var curr = self.open_upvalues;
        while (curr) |up| {
            self.markObject(&up.header);
            curr = up.next_open;
        }
    }

    fn markValue(self: *VM, val: LuaValue) void {
        switch (val) {
            .String => |s| self.markObject(&s.header),
            .Closure => |c| self.markObject(&c.header),
            else => {},
        }
    }

    fn markObject(self: *VM, obj: *GCObject) void {
        if (obj.marked) return;
        obj.marked = true;

        switch (obj.obj_type) {
            .Closure => {
                const c: *ObjClosure = @fieldParentPtr("header", obj);
                self.markObject(&c.proto.header);
                for (c.upvalues) |u_opt| {
                    if (u_opt) |u| self.markObject(&u.header);
                }
            },
            .Upvalue => {
                const u: *ObjUpvalue = @fieldParentPtr("header", obj);
                if (u.location == &u.closed_value) {
                    // Closed: mark the value
                    self.markValue(u.closed_value);
                } else {
                    // Open: do not mark location (it points to stack)
                }
            },
            .Proto => {
                const p: *ObjProto = @fieldParentPtr("header", obj);
                for (p.constants) |k| self.markValue(k);
                // 如果有 nested protos，也要标
            },
            .String => {},
        }
    }

    fn sweep(self: *VM) void {
        var prev: ?*GCObject = null;
        var current = self.objects;
        while (current) |obj| {
            if (!obj.marked) {
                const next = obj.next;
                self.destroyObject(obj);
                if (prev) |p| p.next = next else self.objects = next;
                current = next;
            } else {
                obj.marked = false;
                prev = obj;
                current = obj.next;
            }
        }
    }

    fn destroyObject(self: *VM, obj: *GCObject) void {
        switch (obj.obj_type) {
            .String => {
                const s: *ObjString = @fieldParentPtr("header", obj);
                self.allocator.free(s.bytes);
                self.allocator.destroy(s);
                self.bytes_allocated -= @sizeOf(ObjString); // 简化计算
            },
            .Closure => {
                const c: *ObjClosure = @fieldParentPtr("header", obj);
                self.allocator.free(c.upvalues);
                self.allocator.destroy(c);
                self.bytes_allocated -= @sizeOf(ObjClosure);
            },
            .Upvalue => {
                const u: *ObjUpvalue = @fieldParentPtr("header", obj);
                self.allocator.destroy(u);
                self.bytes_allocated -= @sizeOf(ObjUpvalue);
            },
            .Proto => {
                // Proto 通常是静态分配的，或者由 Compiler 分配。
                // 在这个 Demo 里，我们手动分配 Proto，所以也要释放。
                // 但为了简化，我们假设 Proto 不会被 GC (或者我们在 main 里手动管理)。
                // 如果要 GC Proto，需要更复杂的逻辑。
                // 这里暂不 destroy Proto。
            },
        }
    }

    fn freeAllObjects(self: *VM) void {
        // 简单暴力清空
        var current = self.objects;
        while (current) |obj| {
            const next = obj.next;
            self.destroyObject(obj);
            current = next;
        }
    }
};

// ============================================================================
// 测试：计数器工厂
// ============================================================================
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 整体脚本等价于：
    //   local make_counter = ... -- outer_proto
    //   local c1 = make_counter()
    //   print(c1()); print(c1());
    //   local c2 = make_counter()
    //   print(c2())
    // 为了专注在 VM 行为上，这里我们手动拼出三个 Proto（inner/outer/main），
    // 然后把它们交给 VM 执行。

    // 1. 构造 Inner Proto (计数器函数)
    // function() count = count + 1; return count; end
    // Upvalues: [0] -> count (from parent)
    const inner_consts = [_]LuaValue{
        LuaValue{ .Integer = 1 }, // const[0] = 1，供 ADD 使用
    };
    const inner_code_fixed = [_]Instruction{
        Instruction.init(.GETUPVAL, 0, 0, 0), // R[0] = Upval[0]
        Instruction.init(.LOADK, 1, 0, 0), // R[1] = Const[0] (1)
        Instruction.init(.ADD, 0, 0, 1), // R[0] = R[0] + R[1]
        Instruction.init(.SETUPVAL, 0, 0, 0), // Upval[0] = R[0]
        Instruction.init(.RETURN, 0, 2, 0), // Return R[0]
    };
    const inner_upvals = [_]UpvalueLoc{
        .{ .is_local = true, .index = 0 }, // Capture parent's local 0
    };

    // 我们需要手动分配 Proto，因为它们要被闭包引用
    var inner_proto = ObjProto{
        .header = GCObject{ .next = null, .obj_type = .Proto, .marked = false },
        .code = inner_code_fixed[0..],
        .constants = inner_consts[0..],
        .upvalues = inner_upvals[0..],
        .protos = &[_]*ObjProto{},
    };

    // 2. 构造 Outer Proto (工厂函数)
    // function make_counter() local count=0; return closure(inner); end
    const outer_code = [_]Instruction{
        Instruction.init(.LOADK, 0, 0, 0), // R[0] = Const[0] (0) -> count
        Instruction.init(.CLOSURE, 1, 0, 0), // R[1] = Closure(protos[0])
        Instruction.init(.RETURN, 1, 2, 0), // Return R[1]
    };
    const outer_consts = [_]LuaValue{
        LuaValue{ .Integer = 0 },
    };
    const outer_protos = [_]*ObjProto{
        &inner_proto,
    };

    var outer_proto = ObjProto{
        .header = GCObject{ .next = null, .obj_type = .Proto, .marked = false },
        .code = outer_code[0..],
        .constants = outer_consts[0..],
        .upvalues = &[_]UpvalueLoc{},
        .protos = outer_protos[0..],
    };

    // 3. Main Script (Caller)
    // 对照 Lua 代码：
    //   c1 = make_counter()
    //   c1(); c1()
    //   c2 = make_counter()
    //   c2()
    const main_code = [_]Instruction{
        Instruction.init(.CLOSURE, 0, 0, 0), // R[0] = make_counter (proto 0)
        Instruction.init(.CALL, 0, 1, 2), // c1 = make_counter()
        Instruction.init(.MOVE, 1, 0, 0), // 准备调用 c1()
        Instruction.init(.CALL, 1, 1, 2), // 第一次 c1()

        Instruction.init(.MOVE, 1, 0, 0),
        Instruction.init(.CALL, 1, 1, 2), // 第二次 c1()
        Instruction.init(.CLOSURE, 2, 0, 0), // R[2] = make_counter (proto 0)
        Instruction.init(.CALL, 2, 1, 2), // c2 = make_counter()

        Instruction.init(.MOVE, 3, 2, 0),
        Instruction.init(.CALL, 3, 1, 2), // c2()
        Instruction.init(.RETURN, 0, 1, 0), // halt
    };
    const main_protos = [_]*ObjProto{
        &outer_proto,
    };
    var main_proto = ObjProto{
        .header = GCObject{ .next = null, .obj_type = .Proto, .marked = false },
        .code = main_code[0..],
        .constants = &[_]LuaValue{},
        .upvalues = &[_]UpvalueLoc{},
        .protos = main_protos[0..],
    };

    std.debug.print("=== Lua Closure Demo ===\n", .{});
    var vm = VM.init(allocator);
    defer vm.deinit();

    // Create Root Closure
    const root_closure = try vm.newClosure(&main_proto);

    try vm.execute(root_closure);
}

