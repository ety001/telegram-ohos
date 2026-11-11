/**
 * 状态栏图标占位页面（StatusBarViewExtensionAbility 加载用）。
 * 实际显示的图标由 module.json5 的 icon 配置决定。
 */
@Entry
@Component
struct StatusBarPage {
  build() {
    Column() {
      Text('Telegram')
        .fontSize(14)
        .fontColor('#FFFFFF')
        .width('100%')
        .height('100%')
        .backgroundColor('#00000000')
        .justifyContent(FlexAlign.Center)
    }
    .width('32vp')
    .height('32vp')
  }
}
