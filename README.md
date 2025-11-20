# Zig Lua VM Closure 实现

这是我用 Zig 研究 Lua VM 的实验性代码和我理解的内容整理出的文档。

## 项目简介

本项目包含了一个简化的 Lua 虚拟机实现，重点关注**闭包（Closure）和 Upvalue 机制**。通过这个项目，你可以深入理解：

- Lua 闭包的工作原理
- Upvalue 的 Open/Close 状态转换
- 多个闭包如何共享同一个变量
- 嵌套闭包如何正确继承 Upvalue
- 虚拟机层面的内存管理

## 项目结构

```
.
├── src/
│   └── main.zig          # VM 实现代码
├── docs/
│   └── lua_closure_princple.md  # 详细的原理文档
├── build.zig              # Zig 构建配置
└── README.md              # 本文件
```

## 快速开始

### 前置要求

- [Zig](https://ziglang.org/) 0.11.0 或更高版本

### 编译和运行

```bash
# 编译
zig build

# 运行
zig build run
```

### 预期输出

```
=== Lua Closure Demo ===
RETURN: <closure 0x...>
RETURN: 1
RETURN: 2
RETURN: <closure 0x...>
RETURN: 1
```

## 文档

详细的原理说明请查看 [`docs/lua_closure_princple.md`](docs/lua_closure_princple.md)。

该文档从零开始解释了：

1. **闭包要解决什么问题**：为什么需要闭包机制
2. **基本结构**：Proto、Closure、Upvalue 的关系
3. **Open/Close 机制**：变量如何从栈迁移到堆
4. **完整例子追踪**：通过计数器例子一步步追踪内存变化
5. **多个闭包共享**：如何实现变量共享
6. **Zig 代码实现**：核心代码的详细解释

## 核心概念

### Closure（闭包）

闭包 = 函数代码（Proto）+ 捕获的变量（Upvalue）

```zig
const ObjClosure = struct {
    proto: *ObjProto,        // 函数代码（编译期生成）
    upvalues: []?*ObjUpvalue, // 捕获的外部变量（运行期创建）
};
```

### Upvalue（上值）

被闭包捕获的外部变量，有两种状态：

- **Open 状态**：变量还在栈上，Upvalue 指向栈
- **Close 状态**：变量已复制到堆上，Upvalue 指向自己的存储

### 关键机制

1. **延迟迁移**：变量默认在栈上，只在函数返回时才复制到堆
2. **指针抽象**：通过 `location` 指针，访问代码无需关心状态
3. **共享优化**：多个闭包捕获同一变量时，共享同一个 Upvalue 对象

## 代码特点

这是一个**教学导向的 VM**，为了专注于闭包机制，做了以下简化：

- 单文件实现，便于阅读
- 简化的调用/返回约定
- 简化的 GC 实现（仅保留必要的对象）
- 只实现了 Lua 的一个小子集

## 许可证

本项目仅用于学习和研究目的。

## 参考

- [Lua 5.4 源码](https://www.lua.org/source/5.4/)
- [Zig 官方文档](https://ziglang.org/documentation/)

