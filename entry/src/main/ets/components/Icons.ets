/**
 * 自绘线性图标库（UI 打磨 PR）：替代散落 UI 的裸 emoji 字符（📎 ✕ ▶ 🔍 等），
 * 统一沿仓库「免 emoji 自绘」风格（documentBubble 文件图标先例）。
 *
 * 全部用基础形状（Rect/Circle/Path）绘制，支持 size（vp）与 color 参数；
 * 无外部资源依赖，深浅底均以显式 color 传入保证对比度。
 */

/** 关闭 ✕：两根 45° 交叉圆角短线 */
@Component
export struct CloseIcon {
  iconSize: number = 16;
  iconColor: string = '#7D8E9E';
  lineWidth: number = 2;

  build() {
    Stack() {
      Rect()
        .width(this.iconSize * 0.72)
        .height(this.lineWidth)
        .radius(this.lineWidth / 2)
        .fill(this.iconColor)
        .rotate({ angle: 45 })
      Rect()
        .width(this.iconSize * 0.72)
        .height(this.lineWidth)
        .radius(this.lineWidth / 2)
        .fill(this.iconColor)
        .rotate({ angle: -45 })
    }
    .width(this.iconSize)
    .height(this.iconSize)
  }
}

/** 搜索 🔍：圆环 + 45° 手柄 */
@Component
export struct SearchIcon {
  iconSize: number = 18;
  iconColor: string = '#F5F5F5';
  lineWidth: number = 2;

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Circle()
        .width(this.iconSize * 0.68)
        .height(this.iconSize * 0.68)
        .fillOpacity(0)
        .stroke(this.iconColor)
        .strokeWidth(this.lineWidth)
      Rect()
        .width(this.iconSize * 0.34)
        .height(this.lineWidth)
        .radius(this.lineWidth / 2)
        .fill(this.iconColor)
        .rotate({ angle: 45 })
        .margin({ right: this.iconSize * 0.02, bottom: this.iconSize * 0.06 })
    }
    .width(this.iconSize)
    .height(this.iconSize)
  }
}

/** 附件 ＋：横竖两根短线（加号语义，替代 📎） */
@Component
export struct PlusIcon {
  iconSize: number = 20;
  iconColor: string = '#F5F5F5';
  lineWidth: number = 2;

  build() {
    Stack() {
      Rect()
        .width(this.iconSize * 0.62)
        .height(this.lineWidth)
        .radius(this.lineWidth / 2)
        .fill(this.iconColor)
      Rect()
        .width(this.lineWidth)
        .height(this.iconSize * 0.62)
        .radius(this.lineWidth / 2)
        .fill(this.iconColor)
    }
    .width(this.iconSize)
    .height(this.iconSize)
  }
}

/** 发送纸飞机：经典 send path（实心三角折纸） */
@Component
export struct SendIcon {
  iconSize: number = 18;
  iconColor: string = '#FFFFFF';

  build() {
    Stack() {
      Path()
        .width(this.iconSize)
        .height(this.iconSize)
        .commands('M1.5 2.5 L18.5 9.5 L1.5 16.5 L4.6 9.5 Z')
        .fill(this.iconColor)
    }
    .width(this.iconSize)
    .height(this.iconSize)
  }
}

/** 播放 ▶：实心圆角三角 */
@Component
export struct PlayIcon {
  iconSize: number = 14;
  iconColor: string = '#FFFFFF';

  build() {
    Stack() {
      Path()
        .width(this.iconSize)
        .height(this.iconSize)
        .commands(`M${this.iconSize * 0.28} ${this.iconSize * 0.18} L${this.iconSize * 0.82} ${this.iconSize * 0.5} L${this.iconSize * 0.28} ${this.iconSize * 0.82} Z`)
        .fill(this.iconColor)
    }
    .width(this.iconSize)
    .height(this.iconSize)
  }
}

/** 暂停 ❚❚：两根竖线 */
@Component
export struct PauseIcon {
  iconSize: number = 14;
  iconColor: string = '#FFFFFF';
  lineWidth: number = 2.5;

  build() {
    Row({ space: this.iconSize * 0.18 }) {
      Rect()
        .width(this.lineWidth)
        .height(this.iconSize * 0.62)
        .radius(this.lineWidth / 2)
        .fill(this.iconColor)
      Rect()
        .width(this.lineWidth)
        .height(this.iconSize * 0.62)
        .radius(this.lineWidth / 2)
        .fill(this.iconColor)
    }
    .width(this.iconSize)
    .height(this.iconSize)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
  }
}

/** 返回 ‹：粗折线箭头（替代 ChatPage 的 '<' 文本字符） */
@Component
export struct BackIcon {
  iconSize: number = 20;
  iconColor: string = '#F5F5F5';
  lineWidth: number = 2.4;

  build() {
    Stack() {
      Path()
        .width(this.iconSize * 0.6)
        .height(this.iconSize)
        .commands(`M${this.iconSize * 0.55} ${this.iconSize * 0.06} L${this.iconSize * 0.1} ${this.iconSize * 0.5} L${this.iconSize * 0.55} ${this.iconSize * 0.94}`)
        .fillOpacity(0)
        .stroke(this.iconColor)
        .strokeWidth(this.lineWidth)
        .strokeLineCap(LineCapStyle.Round)
    }
    .width(this.iconSize)
    .height(this.iconSize)
  }
}
